using System.Diagnostics;
using OS7.Setup.Diagnostics;
using OS7.Setup.Model;

namespace OS7.Setup.Steps;

/// <summary>
/// Phase 3 — turning the disk Phase 2 prepared into a system that boots.
///
/// SETUP-PLAN §10: "unsquashfs with real progress; chroot configuration
/// (locale, timezone, hostname, users, zgenhostid, update-initramfs);
/// bootloader install and the grub.d BE generator". The ORDER is spike S3's,
/// steps 6 onwards — `installer/spikes/s3-zfs-luks.sh` is the only evidence in
/// this repository that this sequence produces a machine that starts, and the
/// plan is explicit that the executor should be a front-end over it rather than
/// a re-derivation.
///
/// EVERY STEP TAKES A <see cref="TargetRoot"/>. None of them reaches for
/// `StorageSteps.Target`. See TargetRoot for why that is a decision rather than
/// a style: `Update-OS7` runs this same sequence against a cloned boot
/// environment mounted somewhere else (RELEASE-AND-UPDATE-PLAN §4.2).
/// </summary>
internal static class SystemSteps
{
    /// <summary>Where casper mounts the medium, and so where the squashfs is.</summary>
    public const string Squashfs = "/cdrom/casper/filesystem.squashfs";

    public static List<IStep> For(InstallPlan plan, TargetRoot target) => new()
    {
        new UnsquashfsStep(target),
        new TargetIdentityStep(plan, target),
        new ReleaseIdentityStep(plan, target),
        new AccountStep(plan, target),
        new InstallModeStep(plan, target),
        // AFTER the mode step, and the order is asserted rather than assumed —
        // see the check below. L24: the headless path runs
        // `apt-get autoremove -y --purge`, which removes `network-manager`, so a
        // NetworkManager-rendered netplan written before it names a backend that
        // is no longer installed. Nothing fails at install time; the machine
        // simply comes up with no network.
        new NetworkStep(plan, target),
        new InitramfsStep(plan, target),
        new TpmEnrolStep(plan, target),
        new BootloaderStep(plan, target),
        // LAST BEFORE TEARDOWN, and that position is the whole of what it can
        // promise. Everything after it is the disk being taken away, so its own
        // proof and TeardownStep's export check cannot be in the file it writes
        // — a record of an install cannot contain the end of that install (L31).
        new InstallLogStep(target),
        new TeardownStep(plan, target),
    };

    /// <summary>
    /// The whole install: Phase 2's storage, then Phase 3's system.
    ///
    /// One list rather than two runs, because the Executor's rollback unwinds
    /// what it created and a failure in Phase 3 must still destroy the pools
    /// Phase 2 made. Two Executors would each roll back only their own half, and
    /// the half left behind is the one holding the disk.
    /// </summary>
    public static List<IStep> Everything(InstallPlan plan, TargetRoot target)
    {
        var all = new List<IStep>(StorageSteps.For(plan));
        all.AddRange(For(plan, target));
        return all;
    }
}

// ---------------------------------------------------------------------------
internal sealed class UnsquashfsStep : IStep
{
    private readonly TargetRoot _t;
    public UnsquashfsStep(TargetRoot t) => _t = t;

    public string Describe => "Copying files to the OS/7 boot environment";

    /// <summary>
    /// How far along the copy is, 0..100, for screen 10's progress bar.
    /// Read by the screen on its idle tick; written by the reader thread below.
    /// </summary>
    public static volatile int Percent;

    /// <summary>The file being written, for the line under the bar (§3.1).</summary>
    public static volatile string Current = "";

    public void Run(Executor x)
    {
        if (!x.DryRun && !File.Exists(SystemSteps.Squashfs))
            throw new StepException(
                "Setup cannot find the OS/7 system image on the setup medium.",
                $"stat {SystemSteps.Squashfs}",
                $"{SystemSteps.Squashfs} does not exist. The medium Setup booted "
                + "from is no longer mounted, or is not an OS/7 medium.");

        // THE ESP IS MOUNTED AFTER THIS, NOT BEFORE. `unsquashfs -f` writes
        // /boot wholesale, and a mounted FAT filesystem underneath it is a good
        // way to lose the ESP's contents. S3 says the same thing in the same
        // place, and the ordering is the whole reason it is written down.
        Extract(x);

        x.Exec("mkdir", "-p", _t.Esp);
        x.Exec("mount", StorageSteps.EspPath, _t.Esp);
        x.Created($"the ESP mounted at {_t.Esp}", () => x.TryExec("umount", _t.Esp));

        if (!x.DryRun)
        {
            // Ask the pool how much arrived. "unsquashfs exited 0" is a
            // diagnostic; a used figure of a few hundred megabytes is the thing
            // itself, and the difference is BUILD-NOTES' recurring theme.
            string used = x.Exec("zfs", "list", "-H", "-o", "used", "rpool").Trim();
            Log.Info($"rpool now holds {used}");
            if (!Directory.Exists(_t.At("usr/bin")) || !File.Exists(_t.At("bin/bash")))
                throw new StepException(
                    "Setup copied the system, but the result is not a system.",
                    $"unsquashfs -f -d {_t} {SystemSteps.Squashfs}",
                    $"{_t.At("bin/bash")} is missing after the copy.");
        }
    }

    /// <summary>
    /// `unsquashfs`, reading its progress rather than waiting for it.
    ///
    /// §3.1's screen 10 has a bar and a filename under it, and neither can come
    /// from a process this code has merely started. `-i` makes unsquashfs print
    /// every path as it writes it; without `-n` it also draws a progress bar
    /// with carriage returns, which is unreadable when captured. So: `-i`, no
    /// bar, and the percentage is derived from the file count against the total
    /// unsquashfs reports up front.
    /// </summary>
    private void Extract(Executor x)
    {
        string cmd = $"unsquashfs -f -i -d {_t} {SystemSteps.Squashfs}";
        if (x.DryRun) { Log.Info($"would run: {cmd}"); Percent = 100; return; }
        Log.Info($"run: {cmd}");

        Percent = 0;
        Current = "";

        var psi = new ProcessStartInfo("unsquashfs")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string a in new[] { "-f", "-i", "-d", _t.Root, SystemSteps.Squashfs })
            psi.ArgumentList.Add(a);

        using Process? p = Process.Start(psi)
            ?? throw new StepException("unsquashfs did not start", cmd, "");

        int total = 0, done = 0;
        var tail = new Queue<string>();

        // Read on a thread. unsquashfs writes tens of thousands of lines and a
        // pipe that nobody drains fills up and blocks the process being watched
        // — a progress bar that stops the thing it is measuring.
        var reader = new Thread(() =>
        {
            string? line;
            while ((line = p.StandardOutput.ReadLine()) is not null)
            {
                // "N inodes (M blocks) to write" — the only total on offer.
                if (total == 0 && line.Contains("inodes") && line.Contains("to write"))
                {
                    string first = line.TrimStart().Split(' ')[0];
                    if (int.TryParse(first, out int n) && n > 0) total = n;
                    continue;
                }
                if (!line.StartsWith("create", StringComparison.Ordinal)) continue;

                done++;
                int slash = line.LastIndexOf(_t.Root, StringComparison.Ordinal);
                Current = slash >= 0 ? line[(slash + _t.Root.Length)..] : line;
                if (total > 0) Percent = Math.Min(99, (int)(done * 100L / total));
            }
        }) { IsBackground = true };
        reader.Start();

        string err = p.StandardError.ReadToEnd();
        p.WaitForExit();
        reader.Join(2000);

        foreach (string l in err.ReplaceLineEndings("\n").TrimEnd().Split('\n'))
            if (l.Trim().Length > 0) { tail.Enqueue(l); if (tail.Count > 8) tail.Dequeue(); }

        if (p.ExitCode != 0)
            throw new StepException(
                "Setup could not copy the OS/7 system to the disk.",
                cmd, string.Join('\n', tail));

        Percent = 100;
        Log.Info($"unsquashfs wrote {done} entries" + (total > 0 ? $" of {total}" : ""));
    }
}

// ---------------------------------------------------------------------------
internal sealed class TargetIdentityStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;
    public TargetIdentityStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    public string Describe => "Configuring the system";

    public void Run(Executor x)
    {
        // THE HOSTID, AND IT MUST BE THE LIVE SYSTEM'S, VERBATIM.
        //
        // L13 and BUILD-NOTES: a pool records the hostid of whoever last
        // imported it, and a mismatch makes it refuse to import AT BOOT — the
        // one place there is nothing to fix it with. Phase 2's HostIdStep
        // generated /etc/hostid BEFORE creating the pools, which is the only
        // safe order; this is the other half of it. `cp`, not `zgenhostid` again:
        // a second generation produces a different value and the two halves
        // would disagree.
        x.Exec("install", "-d", _t.At("etc/zfs"));
        x.Exec("cp", "/etc/hostid", _t.At("etc/hostid"));

        // So zfs-import-cache finds bpool at boot without scanning every device.
        if (File.Exists("/etc/zfs/zpool.cache") || x.DryRun)
            x.TryExec("cp", "/etc/zfs/zpool.cache", _t.At("etc/zfs/zpool.cache"));

        string host = _plan.Account.Hostname;
        _t.Write(x, "etc/hostname", host + "\n");
        _t.Write(x, "etc/hosts", $"127.0.0.1\tlocalhost\n127.0.1.1\t{host}\n");

        // Emptied, not deleted: systemd regenerates it on first boot, and a
        // machine-id copied from the live medium would make every machine
        // installed from this ISO the same machine to anything that reads it —
        // including, eventually, a management tenant.
        _t.Write(x, "etc/machine-id", "");

        WriteCrypttab(x);
        WriteFstab(x);

        // D4: swap is zram, never a zvol — swap on ZFS still deadlocks upstream.
        _t.Write(x, "etc/systemd/zram-generator.conf",
                 "[zram0]\nzram-size = min(ram / 2, 4096)\ncompression-algorithm = zstd\n");

        WriteLocaleAndTime(x);
    }

    private void WriteCrypttab(Executor x)
    {
        if (!_plan.Storage.Encrypt)
        {
            Log.Info("no encryption: no crypttab");
            return;
        }
        string uuid = Uuid(x, StorageSteps.LuksPath);

        // `initramfs` IS NOT OPTIONAL. cryptsetup-initramfs decides what to
        // embed by resolving the root device, and with root=ZFS=... it can
        // resolve nothing — so without this keyword the hook embeds NOTHING and
        // the machine stops at an initramfs prompt with no way to unlock rpool.
        // BUILD-NOTES #19 is the same wall from the TPM2 side.
        _t.Write(x, "etc/crypttab",
                 $"{StorageSteps.LuksName} UUID={uuid} none luks,discard,initramfs\n");

        // Belt and braces for the same failure: force the hook on regardless of
        // what cryptsetup-initramfs concludes about the root device.
        _t.Write(x, "etc/cryptsetup-initramfs/conf-hook", "CRYPTSETUP=y\n");
    }

    private void WriteFstab(Executor x)
    {
        // ZFS datasets carry their own mountpoints, so only the ESP belongs
        // here. A generated fstab listing the datasets as well would mount them
        // twice and fight zfs-mount.service for them.
        string uuid = Uuid(x, StorageSteps.EspPath);
        _t.Write(x, "etc/fstab",
                 $"UUID={uuid}  /boot/efi  vfat  umask=0077,shortname=winnt  0  1\n");
    }

    private void WriteLocaleAndTime(Executor x)
    {
        // Screen 3 collected these and until now nothing did anything with them.
        _t.Write(x, "etc/default/locale", $"LANG={_plan.Language}\n");
        _t.Write(x, "etc/locale.conf", $"LANG={_plan.Language}\n");

        // The console keymap the installed system comes up with — the same file
        // the image ships for its own console, with the layout replaced.
        _t.Write(x, "etc/default/keyboard",
                 "XKBMODEL=\"pc105\"\n"
                 + $"XKBLAYOUT=\"{_plan.Keyboard}\"\n"
                 + "XKBVARIANT=\"\"\nXKBOPTIONS=\"\"\nBACKSPACE=\"guess\"\n");

        // A symlink, which is what timedatectl would make and what every tool
        // reading local time expects. Written here rather than by `timedatectl`
        // in the chroot: that needs a running systemd, which a chroot has not.
        if (!x.DryRun && !File.Exists($"/usr/share/zoneinfo/{_plan.Timezone}"))
        {
            Log.Warn($"unknown timezone {_plan.Timezone}; leaving the target on UTC");
            return;
        }
        x.TryExec("rm", "-f", _t.At("etc/localtime"));
        x.Exec("ln", "-sf", $"/usr/share/zoneinfo/{_plan.Timezone}", _t.At("etc/localtime"));
        _t.Write(x, "etc/timezone", _plan.Timezone + "\n");
    }

    private static string Uuid(Executor x, string device)
    {
        if (x.DryRun) return "00000000-0000-0000-0000-000000000000";
        string uuid = x.Exec("blkid", "-s", "UUID", "-o", "value", device).Trim();
        if (uuid.Length == 0)
            throw new StepException(
                "Setup could not identify a partition it had just created.",
                $"blkid -s UUID -o value {device}",
                $"{device} reported no UUID. Without it the installed system "
                + "cannot be told which device to unlock or mount.");
        return uuid;
    }
}

// ---------------------------------------------------------------------------
internal sealed class ReleaseIdentityStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;
    public ReleaseIdentityStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    public string Describe => "Recording the OS/7 release";

    /// <summary>
    /// D8 / L16, and the half of it that until now nothing did.
    ///
    /// The image carries a branded `/etc/os-release` because build hook 0075
    /// wrote one, and `unsquashfs` has just copied that onto the disk — so the
    /// version is already correct. What is NOT correct is `VARIANT`: the image
    /// says what it could be, and the installed system knows what it IS.
    ///
    /// THE FIELDS THAT MUST NOT BE TOUCHED are `ID`, `ID_LIKE` and
    /// `VERSION_ID`. Intune's "Allowed distributions" rule matches on them, and
    /// README makes Intune's constraints outrank OS/7's preferences wherever the
    /// two collide. The product identity lives in `IMAGE_ID`/`IMAGE_VERSION`,
    /// which is what closed D8 without a trade-off.
    ///
    /// Re-asserted rather than assumed correct, because `/etc/os-release` is a
    /// symlink to `/usr/lib/os-release` and `base-files` owns that as a
    /// CONFFILE — an `apt` run can revert it, which is why the update sequence
    /// re-asserts it too (RELEASE-AND-UPDATE-PLAN §4.2 step 6).
    /// </summary>
    public void Run(Executor x)
    {
        Release release = Release.Load(_t.At("usr/lib/os7/release.json"));
        if (!release.Known)
        {
            // Not fatal: a machine with an unbranded os-release boots perfectly
            // well. It is loud, because everything downstream that identifies
            // this install - Intune, a support case, Update-OS7 - reads it.
            Log.Error($"the target has no release manifest at {_t.At("usr/lib/os7/release.json")}; "
                      + "leaving os-release as the image shipped it");
            return;
        }

        string variant = _plan.Mode == InstallMode.Gui ? "GUI" : "Server";
        string variantId = _plan.Mode == InstallMode.Gui ? "gui" : "server";

        // /usr/lib/os-release is the real file; /etc/os-release is a symlink to
        // it. Editing through the symlink works today and breaks silently the
        // day the symlink is not there. BUILD-NOTES #37.
        string target = _t.At("usr/lib/os-release");
        if (x.DryRun)
        {
            Log.Info($"would set VARIANT={variant} in {target}");
            return;
        }
        if (!File.Exists(target))
        {
            Log.Error($"{target} does not exist on the target");
            return;
        }

        var lines = new List<string>();
        bool sawVariant = false, sawVariantId = false;
        foreach (string raw in File.ReadAllLines(target))
        {
            string key = raw.Contains('=') ? raw.Split('=', 2)[0].Trim() : "";
            switch (key)
            {
                case "VARIANT":    lines.Add($"VARIANT=\"{variant}\"");     sawVariant = true; break;
                case "VARIANT_ID": lines.Add($"VARIANT_ID=\"{variantId}\""); sawVariantId = true; break;
                default:           lines.Add(raw); break;
            }
        }
        if (!sawVariant) lines.Add($"VARIANT=\"{variant}\"");
        if (!sawVariantId) lines.Add($"VARIANT_ID=\"{variantId}\"");
        File.WriteAllText(target, string.Join('\n', lines) + "\n");

        // Read it back through the path a program would use, and check that the
        // two fields Intune matches on are still what they were. A step that
        // edits os-release and does not verify the untouched half is a step that
        // can make every device fail a compliance policy silently.
        string? check = _t.Read("etc/os-release") ?? _t.Read("usr/lib/os-release");
        if (check is null || !check.Contains("ID=ubuntu") || !check.Contains("VERSION_ID=\"26.04\""))
            throw new StepException(
                "Setup damaged the operating-system identity on the target.",
                $"edit {target}",
                "ID or VERSION_ID is no longer what Intune's 'Allowed distributions' "
                + "rule matches on. Refusing to continue with a system that would "
                + "fail compliance.");

        Log.Info($"target is OS/7 {release.Version}, VARIANT={variant}");
    }
}

// ---------------------------------------------------------------------------
internal sealed class AccountStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;
    public AccountStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    public string Describe => "Creating the administrator account";

    /// <summary>
    /// THE SQUASHFS HAS NO USERS AT ALL.
    ///
    /// casper creates the live `ubuntu` account at boot, in the overlay, so none
    /// of it survives into an install. Without this step the installed system
    /// boots to a login prompt nobody can get past — which is exactly what spike
    /// S3 hit, and why it created an account of its own.
    ///
    /// AND THE PASSWORD CANNOT GO THROUGH PAM. BUILD-NOTES #17: this image's
    /// password stack runs authd's helper (`pam_authd_exec.so` in
    /// common-password, confirmed in the shipped image on 2026-08-24), which
    /// cannot work inside a chroot:
    ///
    ///     chpasswd: (user os7) pam_chauthtok() failed, error:
    ///     Failed preliminary check by password service
    ///
    /// S3 worked around it with `passwd -d` — an EMPTY password — and said in
    /// its own comments that a real installer must write the hash instead. This
    /// is that. The hash is computed on the LIVE system, where PAM is not
    /// involved at all, and handed to `useradd -p`.
    /// </summary>
    public void Run(Executor x)
    {
        AccountPlan a = _plan.Account;
        if (string.IsNullOrEmpty(a.Username) || string.IsNullOrEmpty(a.Password))
            throw new StepException(
                "Setup has no account to create.",
                "useradd", "No user name or no password reached the executor.");

        string hash = HashPassword(x, a.Password!);

        // Belt and braces: a crypt hash is `$`, `.`, `/` and alphanumerics. It
        // goes into a single-quoted shell string below, so a quote in it would
        // end the string and the rest would be executed. It cannot contain one —
        // check anyway, because "cannot" is what this file keeps disproving.
        if (!x.DryRun && (hash.Contains('\'') || hash.Contains('\n') || hash.Length < 10))
            throw new StepException(
                "Setup could not prepare the account password.",
                "openssl passwd -6 -stdin",
                "The hash is not in the expected form. Refusing to write it.");

        string gecos = a.FullName.Replace(":", " ").Replace("'", "");

        // NO SHELL BRACES IN THE SCRIPT BELOW, and none in its comments either.
        // It is a C# interpolated raw string, so an opening brace starts an
        // interpolation hole: awk's action blocks and bash's ${#VAR} both fail to
        // COMPILE, and the error points at C# rather than at the shell. grep,
        // cut and `wc -c` need none of them.
        //
        // This bit twice - once in the script, once in a comment explaining the
        // first time.

        // -m creates the home directory FROM /etc/skel, which is what makes the
        // first login land somewhere furnished rather than in a bare directory.
        // sudo, because otherwise the only account that can administer the
        // machine is root and root has no password either.
        string script = $"""
            echo ">>> removing casper"
            # The squashfs is a LIVE image. Left installed, casper's initramfs
            # hook ships in an initrd that has no business on an installed
            # system. Inert without boot=casper, but removed rather than trusted.
            dpkg --purge casper >/dev/null 2>&1 || echo "    (casper purge skipped)"

            echo ">>> creating {a.Username}"
            useradd -m -s /bin/bash -G sudo -c '{gecos}' -p '{hash}' '{a.Username}'

            # Proof, FROM /etc/shadow rather than from useradd's exit code: an
            # account whose shadow entry has no hash is an account that cannot
            # log in, and useradd exits 0 either way.
            #
            # READ the field, do not match a pattern against it. The first
            # version used a regex whose '$' the shell ate, so it became "the
            # line ends after the colon" - which matches an account with an EMPTY
            # password and fails on a correct one. It would have failed every
            # install, and it was found by reading the bash this generates
            # rather than by running it.
            HASH=$(grep "^{a.Username}:" /etc/shadow | cut -d: -f2)
            case "$HASH" in
                '' | '!'* | '*'*)
                    echo "!!! {a.Username} has no usable password hash" >&2
                    exit 1 ;;
            esac
            LEN=$(printf '%s' "$HASH" | wc -c)
            if [ "$LEN" -lt 20 ]; then
                echo "!!! the password hash for {a.Username} is $LEN characters" >&2
                exit 1
            fi
            echo "    /etc/shadow holds a $LEN-character hash for {a.Username}"
            id '{a.Username}'
            """;

        _t.Chroot(x, $"creating {a.Username}", script);
    }

    /// <summary>
    /// A crypt(3) hash, made OUTSIDE the chroot and outside PAM.
    ///
    /// `openssl passwd -6` gives SHA-512 crypt, which every libcrypt in this
    /// stack accepts. The image's pam_unix defaults new passwords to yescrypt
    /// (`etc/pam.d/common-password`, measured), and that is about what it
    /// GENERATES — it verifies whatever the shadow entry actually holds.
    ///
    /// `-stdin`, so the password is never in argv and therefore never in `ps`
    /// or in the log Setup offers to export to removable media.
    ///
    /// python3 was the obvious alternative and is not available for this:
    /// `crypt` was removed from the standard library in Python 3.13 and the
    /// image ships 3.14.
    /// </summary>
    private static string HashPassword(Executor x, string password)
    {
        if (x.DryRun) return "$6$dryrun$dryrun";
        string hash = x.ExecSecret("openssl", password, "passwd", "-6", "-stdin").Trim();
        if (!hash.StartsWith("$6$", StringComparison.Ordinal))
            throw new StepException(
                "Setup could not hash the account password.",
                "openssl passwd -6 -stdin",
                $"Expected a $6$ SHA-512 crypt hash, got {hash.Length} characters "
                + "that do not begin with $6$.");
        return hash;
    }
}

// ---------------------------------------------------------------------------
internal sealed class InstallModeStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;
    public InstallModeStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    public string Describe => _plan.Mode == InstallMode.Gui
        ? "Configuring the desktop" : "Configuring a headless system";

    /// <summary>
    /// The GUI/headless split, done OFFLINE.
    ///
    /// README makes this an install-time choice over ONE shared package base per
    /// architecture: the image carries the desktop, and headless removes it.
    /// Removal rather than addition, because an installer that has to fetch
    /// packages is an installer that fails without a network — and the machines
    /// this is for are often installed before they have one.
    ///
    /// arm64 has nothing to do here at all: it is server-only (README), ships no
    /// desktop, and the question is never asked.
    /// </summary>
    public void Run(Executor x)
    {
        if (_plan.Mode == InstallMode.Gui)
        {
            _t.Chroot(x, "graphical target", """
                systemctl set-default graphical.target
                systemctl enable gdm3 2>/dev/null || echo "    (no gdm3 to enable)"
                """);
            return;
        }

        // `apt-get purge` with no network: every package is already unpacked on
        // the target, and removal needs no archive.
        _t.Chroot(x, "headless", """
            systemctl set-default multi-user.target

            # Nothing to remove on an image that never had a desktop (arm64).
            if dpkg -l ubuntu-desktop-minimal 2>/dev/null | grep -q '^ii'; then
                echo ">>> removing the desktop"
                apt-get purge -y --allow-remove-essential \
                    ubuntu-desktop-minimal gnome-shell gdm3 nautilus gnome-terminal \
                    >/dev/null 2>&1 || echo "    (partial desktop removal)"
                apt-get autoremove -y --purge >/dev/null 2>&1 || true
            else
                echo "    no desktop on this image - nothing to remove"
            fi

            # Proof from the thing itself, not from apt's exit code.
            echo ">>> default target is now: $(systemctl get-default)"
            """);
    }
}

// ---------------------------------------------------------------------------
internal sealed class InitramfsStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;
    public InitramfsStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    public string Describe => "Building the startup image";

    /// <summary>
    /// The initramfs, and then THE CHECK THAT IT CAN ACTUALLY UNLOCK AND IMPORT.
    ///
    /// Spike S3 added that check and it is the reason this step is not four
    /// lines long. `update-initramfs` exits 0 having embedded nothing useful,
    /// and the symptom is a machine that reaches an initramfs prompt fifteen
    /// minutes later with no way to tell whether the bootloader, the crypttab or
    /// the hook was at fault. Checking the artefact costs seconds.
    ///
    /// One correction S3 itself needed, and it is worth keeping in view: the
    /// path is `cryptroot/crypttab`, NOT the pre-2.x `conf/conf.d/cryptroot`.
    /// At initramfs stage `/lib/cryptsetup/functions` sets
    /// `TABFILE=/cryptroot/crypttab`. Checking the old path reports a missing
    /// unlock config on an image that has a perfectly good one — a diagnostic
    /// that did not check the thing it claimed to.
    /// </summary>
    public void Run(Executor x)
    {
        var want = new List<string> { "scripts/zfs", "etc/hostid" };
        if (_plan.Storage.Encrypt)
        {
            want.Add("cryptsetup");
            want.Add("cryptroot/crypttab");
        }
        // `zpool` in the initramfs comes from zfs-initramfs; without it the
        // pool cannot be imported before the real root exists.
        want.Add("zpool");

        // Built by concatenation rather than as an indented raw string per item:
        // a raw string inside a lambda takes its indentation from its own closing
        // delimiter, and the result is bash whose here-doc-adjacent whitespace is
        // decided by C# formatting. This is uglier to read and impossible to get
        // wrong by reindenting the file.
        string checks = string.Join("\n", want.Select(w =>
            "if grep -q '" + w + "' /tmp/initrd.list; then\n"
            + "    echo \"    ok       " + w + "\"\n"
            + "else\n"
            + "    echo \"    MISSING  " + w + "\"\n"
            + "    FAULTS=\"$FAULTS " + w + "\"\n"
            + "fi"));

        string script = $"""
            echo ">>> update-initramfs"
            update-initramfs -u -k all || update-initramfs -c -k all

            IMG=$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
            if [ -z "$IMG" ]; then
                echo "!!! update-initramfs produced no /boot/initrd.img-*" >&2
                exit 1
            fi
            echo ">>> checking $IMG can unlock and import"
            lsinitramfs "$IMG" > /tmp/initrd.list
            FAULTS=""
            {checks}

            if [ -n "$FAULTS" ]; then
                echo "!!! the startup image is missing:$FAULTS" >&2
                echo "!!! what it actually carries:" >&2
                grep -E 'cryptroot|hostid|scripts/zfs|sbin/(zpool|cryptsetup)$' \
                    /tmp/initrd.list | head -20 >&2 || true
                exit 1
            fi
            echo ">>> the startup image is complete"
            """;

        _t.Chroot(x, "initramfs", script);
    }
}

// ---------------------------------------------------------------------------
internal sealed class TpmEnrolStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;
    public TpmEnrolStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    public string Describe => "Sealing the disk key to the TPM";

    /// <summary>
    /// TPM2 auto-unlock. Decided into Phase 3 on 2026-08-24, and it is NOT
    /// `systemd-cryptenroll` on its own.
    ///
    /// BUILD-NOTES #19: `systemd-cryptenroll --tpm2-device=auto` writes a valid
    /// LUKS2 token, exits 0, and CHANGES NOTHING AT BOOT — `cryptsetup-initramfs`
    /// has no concept of LUKS2 tokens, so the initramfs still only knows about
    /// the passphrase keyslot.
    ///
    /// BUILD-NOTES #20: and the hook that would carry the token handler cannot
    /// be built by walking ELF `NEEDED`, because systemd **dlopens** the whole
    /// TPM stack. `copy_exec` sees nothing, and an initramfs built that way gets
    /// the handler and no libtss2 at all.
    ///
    /// So this step installs the pieces spike S4 proved
    /// (`installer/spikes/s4-tpm-enroll.sh` is the working version), enrols, and
    /// then rebuilds the initramfs so they are in it.
    ///
    /// BEST EFFORT, DELIBERATELY. A machine with no TPM, a TPM the firmware
    /// hides, or a PCR set that will not seal must still finish installing and
    /// still boot — on the passphrase, which is intact either way. Spike S6
    /// measured what a broken seal looks like and it is benign: cryptsetup names
    /// the cause and the passphrase path still works.
    ///
    /// WHAT THIS DOES NOT SOLVE is U8, the escrowed recovery passphrase that
    /// unattended re-enrolment would need after a Secure Boot policy change.
    /// That is a key-management design, it is open, and the layout screen says
    /// so where the operator can still act on it.
    /// </summary>
    public void Run(Executor x)
    {
        if (!_plan.Storage.Encrypt)
        {
            Log.Info("no encryption: nothing to seal");
            return;
        }
        if (string.IsNullOrEmpty(_plan.Storage.Passphrase))
        {
            Log.Warn("no passphrase in hand: cannot enrol the TPM");
            return;
        }

        if (!x.DryRun && !Directory.Exists("/sys/class/tpm/tpm0"))
        {
            // Said plainly rather than attempted and failed. A machine without a
            // TPM is a supported machine (S4 checked exactly that case); it just
            // asks for the passphrase every time.
            Log.Info("no TPM on this machine: the passphrase will be asked for at every start");
            return;
        }

        // The initramfs pieces, written before enrolling: an enrolment that
        // works with no hook to use it is the #19 failure with extra steps.
        _t.Write(x, "etc/initramfs-tools/hooks/os7-tpm2", TpmHook, "0755");
        _t.Write(x, "etc/initramfs-tools/scripts/local-top/os7-tpm2", TpmLocalTop, "0755");

        // systemd-cryptenroll needs the existing passphrase to unlock the
        // container before it can add a keyslot. PASSWORD ON STDIN, via the
        // environment variable systemd reads, so it is never in argv.
        string enrol = $"""
            echo ">>> enrolling the TPM"
            # PCR 7 is Secure Boot policy. S6 measured that it survives kernel
            # and initramfs updates byte-identical, and does NOT survive a
            # Secure Boot policy change - which is the correct behaviour and is
            # recoverable with one re-enrolment.
            if systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \
                 --unlock-key-file=/tmp/os7-pass {StorageSteps.LuksPath}; then
                echo "    sealed to PCR 7"
            else
                echo "    NOTE: the TPM would not take the key; the passphrase still works"
                exit 0
            fi

            echo ">>> rebuilding the startup image with the TPM handler"
            update-initramfs -u -k all

            IMG=$(ls -1 /boot/initrd.img-* | sort -V | tail -1)
            lsinitramfs "$IMG" > /tmp/initrd2.list
            # BUILD-NOTES #20: the libraries systemd DLOPENS are the half that
            # goes missing, and their absence is invisible until a boot that
            # asks for a passphrase nobody expected.
            for want in libtss2-esys libtss2-rc; do
                if grep -q "$want" /tmp/initrd2.list; then
                    echo "    ok       $want"
                else
                    echo "    MISSING  $want - TPM unlock will not work at boot"
                fi
            done

            # THE ONE THAT DECIDES WHETHER ANY OF THIS WORKS. `cryptsetup open
            # --token-only` needs the LUKS2 token handler, which lives in a
            # directory the stock initramfs hook does not touch. Without it the
            # unlock cannot succeed, however correct the enrolment is —
            # BUILD-NOTES #19, #20, #66.
            if grep -q 'libcryptsetup-token-systemd-tpm2.so' /tmp/initrd2.list; then
                echo "    ok       libcryptsetup-token-systemd-tpm2.so"
            else
                echo "    MISSING  libcryptsetup-token-systemd-tpm2.so - the TPM cannot unlock"
            fi
            # The TCTI backend that talks to /dev/tpmrm0, dlopened by name.
            if grep -q 'libtss2-tcti-device' /tmp/initrd2.list; then
                echo "    ok       libtss2-tcti-device"
            else
                echo "    MISSING  libtss2-tcti-device - nothing can reach /dev/tpmrm0"
            fi

            # And the handler script itself, which nothing else checks.
            if grep -q '^scripts/local-top/os7-tpm2$' /tmp/initrd2.list; then
                echo "    ok       scripts/local-top/os7-tpm2"
            else
                echo "    MISSING  scripts/local-top/os7-tpm2 - nothing will try the TPM"
            fi

            # THE ORDER, OBSERVED. initramfs-tools computes it at build time with
            # `get_prereq_pairs | tsort`, and reasoning about how tsort breaks
            # ties predicted the opposite of the truth once already. Read the
            # ORDER file out of the image that was just built.
            rm -rf /tmp/os7-ird && mkdir -p /tmp/os7-ird
            if unmkinitramfs "$IMG" /tmp/os7-ird 2>/dev/null; then
                R=/tmp/os7-ird
                [ -d "$R/main" ] && R="$R/main"
                O="$R/scripts/local-top/ORDER"
                t=$(grep -n 'local-top/os7-tpm2' "$O" 2>/dev/null | head -1 | cut -d: -f1)
                c=$(grep -n 'local-top/cryptroot' "$O" 2>/dev/null | head -1 | cut -d: -f1)
                if [ -n "$t" ] && [ -n "$c" ] && [ "$t" -lt "$c" ]; then
                    echo "    ok       os7-tpm2 runs before cryptroot"
                else
                    echo "    WRONG    os7-tpm2 ($t) does not precede cryptroot ($c)"
                    sed 's/^/             /' "$O" 2>/dev/null
                fi
            fi
            """;

        try
        {
            // The passphrase reaches the chroot as a file, deleted immediately.
            if (!x.DryRun)
            {
                File.WriteAllText(_t.At("tmp/os7-pass"), _plan.Storage.Passphrase);
                x.Exec("chmod", "0600", _t.At("tmp/os7-pass"));
            }
            _t.Chroot(x, "TPM2 enrolment", enrol);
        }
        catch (StepException ex)
        {
            // NOT FATAL. The whole point of the passphrase path is that it works
            // when this does not. Recorded loudly; the install continues.
            Log.Error($"TPM enrolment failed: {ex.Message} / {ex.Output}");
        }
        finally
        {
            if (!x.DryRun)
                try { File.Delete(_t.At("tmp/os7-pass")); } catch { /* pool may be gone */ }
        }
    }

    /// <summary>
    /// The initramfs hook. `copy_exec` for the binaries, and then the libtss2
    /// libraries BY PATH — because systemd dlopens them and nothing walking ELF
    /// dependencies will ever find them (BUILD-NOTES #20).
    /// </summary>
    private const string TpmHook = """
        #!/bin/sh
        # OS/7 - carry the TPM2 stack into the initramfs.
        #
        # copy_exec CANNOT SEE A DLOPEN. systemd dlopens the whole TPM stack, so
        # an initramfs built by walking ELF NEEDED gets the token handler and no
        # libtss2 at all - and the failure is a passphrase prompt on a machine
        # that was supposed to unlock itself. BUILD-NOTES #20.
        PREREQ=""
        prereqs() { echo "$PREREQ"; }
        case "$1" in prereqs) prereqs; exit 0;; esac
        . /usr/share/initramfs-tools/hook-functions

        # THE TOKEN HANDLER IS THE POINT, and this step did not carry it for a
        # release. `cryptsetup` loads external LUKS2 token handlers from a
        # compiled-in directory, /usr/lib/<triplet>/cryptsetup, and the stock
        # cryptsetup-initramfs hook copies NONE of them — so `cryptsetup open
        # --token-only` inside the initramfs can only fail. That is what
        # BUILD-NOTES #19 and #20 are about, and installer/spikes/s4-tpm-enroll.sh
        # is the version that was proved to boot. This step had diverged from it
        # (BUILD-NOTES #66).
        found=
        for so in /usr/lib/*/cryptsetup/libcryptsetup-token-systemd-tpm2.so; do
            [ -e "$so" ] || continue
            copy_exec "$so"
            found=y
        done
        [ -n "$found" ] && echo "os7-tpm2: token handler copied" \
                        || echo "os7-tpm2: libcryptsetup-token-systemd-tpm2.so NOT FOUND" >&2

        # copy_exec follows ELF NEEDED and that is not enough. The handler links
        # libsystemd-shared, which DLOPENS the TPM stack as an optional feature,
        # and libtss2-tctildr dlopens a TCTI backend by name — /dev/tpmrm0 is
        # served by libtss2-tcti-device.so.0. Nothing walking NEEDED sees any of
        # them, so they are named. BUILD-NOTES #20.
        for lib in libtss2-esys.so.0 libtss2-mu.so.0 libtss2-rc.so.0 \
                   libtss2-tcti-device.so.0; do
            for cand in /usr/lib/*/"$lib" /usr/lib/"$lib"; do
                [ -e "$cand" ] || continue
                copy_exec "$cand"
                break
            done
        done

        # And the TPM device nodes' udev rules, so /dev/tpmrm0 exists in time.
        for r in /usr/lib/udev/rules.d/*tpm*.rules; do
            [ -f "$r" ] && mkdir -p "${DESTDIR}/usr/lib/udev/rules.d" \
                && cp -a "$r" "${DESTDIR}/usr/lib/udev/rules.d/"
        done
        exit 0
        """;

    /// <summary>
    /// The local-top script, which must run BEFORE `cryptroot`.
    ///
    /// `/scripts/zfs`'s `pre_mountroot()` runs `local-top` before importing, so
    /// this is where an unlock has to happen for the pool to be there when ZFS
    /// looks. Prereq on nothing and ordered by name ahead of `cryptroot` — if
    /// this succeeds, cryptroot finds the mapping already open and does nothing.
    /// </summary>
    private const string TpmLocalTop = """
        #!/bin/sh
        # OS/7 - try the TPM before falling through to the passphrase prompt.
        PREREQ=""
        prereqs() { echo "$PREREQ"; }
        case "$1" in prereqs) prereqs; exit 0;; esac

        # EVERY REASON TO GIVE UP SAYS SO. This script used to fail at its second
        # line and exit 0, which is indistinguishable at boot from a machine that
        # has no TPM - and that is exactly what happened for one whole release:
        # the enrolment was perfect, the token was in the header, the handler and
        # the libraries were in the initramfs, and this asked for a path that
        # does not exist any more. BUILD-NOTES #64.
        say() { echo "OS/7 TPM: $1" >&2; }

        [ -e /dev/tpmrm0 ] || { say "no /dev/tpmrm0 - falling back to the passphrase"; exit 0; }

        # READ WITH THE SHELL, not with sed. The initramfs's sed is busybox's,
        # and `\+` is a GNU extension that its build need not carry - a regex
        # that works perfectly on the installed system matches nothing here and
        # says nothing about why. `while read` has no dialect.
        TAB=/cryptroot/crypttab
        [ -s "$TAB" ] || { say "$TAB is missing or empty"; exit 0; }

        mkdir -pm0700 /run/cryptsetup

        # `cryptsetup open --token-only`, NOT `systemd-cryptsetup attach`. This
        # is the invocation spike S4 proved boots (installer/spikes/s4-tpm-enroll.sh),
        # and it is the one the hook above carries the token handler for.
        # --token-only never falls back to a passphrase, so a TPM that is absent,
        # sealed against different PCRs, or simply unwilling leaves this a no-op
        # and the stock cryptroot script prompts exactly as it always did. That
        # IS the recovery path, and S6 measured it.
        opened=
        while read -r name source key options; do
            case "$name" in ''|\#*) continue ;; esac
            case "$source" in
                UUID=*) dev="/dev/disk/by-uuid/${source#UUID=}" ;;
                *)      dev="$source" ;;
            esac
            [ -b "$dev" ] || { say "$name: $dev is not there"; continue; }
            [ -e "/dev/mapper/$name" ] && { opened=y; continue; }
            if /sbin/cryptsetup open --token-only -- "$dev" "$name" 2>/dev/null; then
                say "unlocked $name from the TPM"
                opened=y
            else
                say "the TPM would not unlock $name - the passphrase still works"
            fi
        done < "$TAB"
        [ -n "$opened" ] || say "nothing was unlocked from the TPM"
        exit 0
        """;
}

// ---------------------------------------------------------------------------
internal sealed class BootloaderStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;
    public BootloaderStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    public string Describe => "Installing the bootloader";

    /// <summary>
    /// GRUB, and the four things that decide whether this machine starts.
    ///
    /// 1. `boot=zfs` IS MANDATORY on the kernel command line, and NOTHING
    ///    GENERATES IT. BUILD-NOTES #15, and the single most expensive finding
    ///    in spike S3. `initramfs-tools` defaults `BOOT=local`, `scripts/local`
    ///    has no ZFS handling at all, and `10_linux_zfs` emits only `root=ZFS=`.
    ///    Without it the initramfs tries to mount the literal string
    ///    "ZFS=rpool/ROOT/…" as a device and drops to a prompt.
    ///
    ///    It also buys the LUKS ordering for free: `/scripts/zfs`'s
    ///    `pre_mountroot()` runs `/scripts/local-top` before importing, so
    ///    cryptroot always unlocks before the pool is looked for.
    ///
    /// 2. `root=ZFS=` MUST NOT BE PINNED in `GRUB_CMDLINE_LINUX`. L4:
    ///    `10_linux_zfs` emits one per boot environment, and anything appended
    ///    via `GRUB_CMDLINE_LINUX` lands after it and therefore wins — so
    ///    pinning a dataset makes every entry in the menu boot the same one,
    ///    which is exactly the feature the layout exists for.
    ///
    /// 3. THE REMOVABLE PATH FIRST. `\EFI\BOOT\BOOTAA64.EFI` is what firmware
    ///    boots when NVRAM holds no entry — a cleared CMOS, a disk moved to
    ///    another machine, a USB install. It needs no efivars, so it is the one
    ///    that must work; the NVRAM entry is best effort on top.
    ///
    /// 4. AND THE MENU HAS TO SAY OS/7. L4's complaint is that the entries are
    ///    titled from `/etc/os-release`'s `PRETTY_NAME`, which read
    ///    "Ubuntu 26.04 LTS". Hook 0075 now brands that, so `GRUB_DISTRIBUTOR`
    ///    plus the branded PRETTY_NAME make the menu name the product. Checked
    ///    below rather than assumed.
    /// </summary>
    public void Run(Executor x)
    {
        string efiTarget = RuntimeArch is "arm64" ? "arm64-efi" : "x86_64-efi";

        // The console= tokens are NOT here. S3 put them in because it drove the
        // whole boot over a serial line; an installed machine gets whatever its
        // firmware gives it, and pinning ttyAMA0 on hardware that has none
        // produces a boot with no visible output at all.
        // GRUB_DEFAULT=saved, NOT 0. `saved` is the only setting under which
        // GRUB reads `saved_entry` out of grubenv, and `saved_entry` is the only
        // place a boot environment can be NAMED as the default. It matters
        // because 10_linux_zfs sorts the menu by last-used and hands the running
        // system the current time, so the environment that generated the menu is
        // always its first entry — and with GRUB_DEFAULT=0 a rollback could
        // therefore never take effect. See powershell/OS7/OS7.psm1,
        // Set-OS7BootEnvironment, which is the code that depends on this.
        //
        // It is set here rather than repaired at the first rollback on purpose:
        // the first rollback happens on a machine that has just stopped working,
        // and that is the wrong moment to be editing /etc/default/grub.
        _t.Write(x, "etc/default/grub", $"""
            GRUB_DEFAULT=saved
            GRUB_TIMEOUT=5
            GRUB_TIMEOUT_STYLE=menu
            GRUB_DISTRIBUTOR="OS/7"
            GRUB_CMDLINE_LINUX="boot=zfs"
            GRUB_CMDLINE_LINUX_DEFAULT=""
            GRUB_DISABLE_OS_PROBER=true
            GRUB_DISABLE_RECOVERY=true

            """);

        string script = $"""
            echo ">>> grub-install (removable path)"
            # The one that must work: no efivars needed, and it is what boots a
            # disk whose NVRAM entry does not exist or has been cleared.
            grub-install --target={efiTarget} --efi-directory=/boot/efi \
                --removable --recheck

            echo ">>> grub-install (NVRAM entry)"
            # Needs a writable efivarfs. Best effort - the removable path above
            # stands in when the firmware will not take an entry.
            grub-install --target={efiTarget} --efi-directory=/boot/efi \
                --bootloader-id=OS7 --recheck --no-floppy \
                || echo "    NOTE: no NVRAM entry (efivars unavailable?) - removable path stands in"

            echo ">>> update-grub"
            update-grub

            # WHICH GENERATOR PRODUCED THE ENTRIES MATTERS, so ask rather than
            # assume. grub.d/10_linux hands ZFS to 10_linux_zfs whenever that
            # file exists; 10_linux_zfs is the zsys-era boot-environment
            # generator and looks for a dataset whose mountpoint is '/', which an
            # altroot'd install may not present. If it emitted nothing, stand it
            # down and let plain 10_linux do it - that path resolves the ZFS root
            # itself and needs no code of ours.
            if ! grep -q "root=ZFS" /boot/grub/grub.cfg; then
                echo "    10_linux_zfs produced no ZFS entry - falling back to 10_linux"
                chmod -x /etc/grub.d/10_linux_zfs 2>/dev/null || true
                update-grub
            fi

            # GRUB_DEFAULT=saved above means the default is whatever grubenv
            # names, so it has to be named. Read out of the menu that was just
            # generated rather than constructed: the id carries the kernel
            # version, and a constructed one would be stale the first time this
            # machine takes a new kernel. There is exactly one boot environment
            # at install time, so the first entry naming rpool/ROOT is it.
            echo ">>> naming the default menu entry"
            ENTRY="$(grep -oE "'gnulinux-rpool/ROOT/[^']+'" /boot/grub/grub.cfg \
                     | head -1 | tr -d "'")"
            if [ -n "$ENTRY" ]; then
                grub-editenv /boot/grub/grubenv set "saved_entry=$ENTRY"
                echo "    default: $ENTRY"
            else
                # Not fatal: an unset saved_entry leaves GRUB on the first entry,
                # which on a one-environment machine is the same entry. Said out
                # loud because on a machine with two it would not be.
                echo "    NOTE: no boot-environment entry found to name as default"
            fi

            echo ">>> checking the menu can actually boot this system"
            FAULTS=""
            grep -q "root=ZFS=" /boot/grub/grub.cfg \
                || FAULTS="$FAULTS no-root-dataset"
            # BUILD-NOTES #15. If this is missing the machine reaches an
            # initramfs prompt, and it is the check that costs seconds instead
            # of a boot cycle.
            grep -q "boot=zfs"  /boot/grub/grub.cfg \
                || FAULTS="$FAULTS no-boot=zfs"
            # `ls`, not `[ -f glob ]`: with more than one match the test gets
            # several arguments and complains about them instead of answering.
            ls /boot/efi/EFI/BOOT/BOOT*.EFI >/dev/null 2>&1 \
                || FAULTS="$FAULTS no-removable-loader"

            echo ">>> the menu entries:"
            grep -E "^menuentry |root=ZFS|boot=zfs" /boot/grub/grub.cfg | head -12 | sed 's/^/    /'

            if [ -n "$FAULTS" ]; then
                echo "!!! the bootloader is not able to start this system:$FAULTS" >&2
                exit 1
            fi
            echo ">>> the bootloader is installed and the menu resolves a boot environment"
            """;

        _t.Chroot(x, "bootloader", script);

        // L4, checked from OUTSIDE the chroot on the file itself: the menu must
        // name the product. Not fatal - a machine that boots with the wrong
        // title is a cosmetic problem and a machine that does not boot is not -
        // but it is the check that keeps D8 honest now that something writes it.
        if (!x.DryRun)
        {
            string cfg = _t.Read("boot/grub/grub.cfg") ?? "";
            if (cfg.Contains("OS/7"))
                Log.Info("the GRUB menu names OS/7");
            else
                Log.Warn("the GRUB menu does not name OS/7 - L4 is not closed on this install");
        }
    }

    /// <summary>
    /// The architecture GRUB has to be built for.
    ///
    /// From the RUNNING process, not from the plan: Setup is a native binary and
    /// the machine it is installing is the machine it is running on. A plan file
    /// written on one architecture and replayed on another would otherwise
    /// install a bootloader the firmware cannot execute.
    /// </summary>
    private static string RuntimeArch => System.Runtime.InteropServices.RuntimeInformation
        .OSArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "amd64";
}

// ---------------------------------------------------------------------------
/// <summary>
/// Put the log on the disk, because the one Setup is writing to is about to
/// cease to exist.
///
/// SETUP-PLAN L31. `Log.Path` is `/var/log/os7-setup/setup.log` on the LIVE
/// system, which is casper's RAM overlay, so screen 12's restart discards it.
/// What goes with it is every step's self-proof — AccountStep reading the hash
/// length back out of /etc/shadow, InitramfsStep listing what the initrd
/// contains, NetworkStep reading back the unit netplan generated,
/// BootloaderStep checking the menu resolves a boot environment. None of that is
/// missed on a machine that boots. On a machine that boots WRONG it is the only
/// record of what was done to it, and it is gone before anybody can look.
///
/// WHY IT IS A STEP AND NOT SOMETHING TeardownStep DOES ON ITS WAY PAST: it has
/// to be able to fail visibly. A step has a name on screen 11 and an entry in
/// the log; a side-effect tucked into the unmount sequence has neither, and a
/// silent failure here produces a screen 12 that names a file nobody wrote.
///
/// IT IS NOT FATAL. The machine on the disk is finished and correct by the time
/// this runs — refusing to complete an install over a missing log would trade a
/// working computer for a diagnostic about one. It is recorded loudly instead,
/// and <see cref="Log.Kept"/> stays null so screen 12 says so rather than
/// pointing at a path.
/// </summary>
internal sealed class InstallLogStep : IStep
{
    private readonly TargetRoot _t;
    public InstallLogStep(TargetRoot t) => _t = t;

    public string Describe => "Saving the installation record";

    /// <summary>Where it goes inside the target: `Log.Installed` without its leading slash.</summary>
    private static string Relative => Log.Installed.TrimStart('/');

    public void Run(Executor x)
    {
        string path = _t.At(Relative);

        // 0600. The audit that says nothing in the ring is a secret is in
        // Log.LiveOnly, and it was done by reading every Log call rather than by
        // trusting the shape of them: the passphrase reaches `cryptsetup`
        // through a keyfile in /run and never through argv; the account password
        // reaches `openssl` through ExecSecret's stdin; the crypt hash reaches
        // `useradd` inside a chroot SCRIPT, and the script's text is logged only
        // under --dry-run, where the hash is a constant. Chroot logs what the
        // scripts SAY BACK, and the closest any of them comes is the length of a
        // SHA-512 crypt hash, which is the same number for every password.
        //
        // 0600 anyway. The four lines that describe a secret are redacted by
        // `persistent: true`, and the reasoning above has to stay right for
        // every line anyone adds later. Mode is the half of this that does not
        // depend on that staying true.
        try
        {
            _t.Write(x, Relative, Log.Transcript(persistent: true), "0600");
        }
        catch (Exception ex)
        {
            Log.Error($"the installation record could not be written to {path}: {ex.Message}");
            return;
        }

        if (x.DryRun) { Log.Kept = Log.Installed; return; }

        // READ IT BACK OUT OF THE TARGET. `Write` returning is a diagnostic; the
        // file having the log in it is the thing itself, and the two come apart
        // in the one case that matters here — a pool that has filled up, where
        // the write succeeds and the content is short or absent.
        string? back = _t.Read(Relative);
        if (back is null)
        {
            Log.Error($"the installation record is not at {path} after writing it");
            return;
        }

        // Not "is it non-empty": the header alone would pass that, and the
        // header is written by the same call that would have failed to carry the
        // ring. A `step:` line is a line that came from the ring.
        int steps = back.Split('\n').Count(l => l.Contains("step: "));
        if (steps < 2)
        {
            Log.Error($"the installation record at {path} is {back.Length} bytes and "
                      + $"holds {steps} step line(s) — the log did not reach it");
            return;
        }

        // The mode, ASKED OF THE FILE. `Write` runs chmod and would have thrown,
        // but that is the chmod's exit code rather than the file's mode, and the
        // difference is the recurring one in BUILD-NOTES.
        string mode = x.TryExec("stat", "-c", "%a", path).Trim();
        if (mode != "600")
        {
            Log.Error($"the installation record at {path} is mode {mode}, not 600");
            return;
        }

        Log.Kept = Log.Installed;
        Log.Info($"the installation record is on the target: {path}, "
                 + $"{back.Length} bytes, mode {mode}, {steps} steps");
    }
}

// ---------------------------------------------------------------------------
internal sealed class TeardownStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;
    public TeardownStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    public string Describe => "Finishing";

    /// <summary>
    /// Unmount everything and EXPORT BOTH POOLS, in spike S3's order.
    ///
    /// THE ORDER IS THE WHOLE STEP. `bpool` is mounted at `<target>/boot`, which
    /// is INSIDE `rpool`'s tree — so exporting rpool first cannot work, and does
    /// not fail loudly either: `zpool export rpool` returns non-zero, and if
    /// nobody looks, the install "succeeds" with a pool still imported.
    ///
    /// That is exactly what the first Phase 3 run did. All fourteen steps ran,
    /// the installer reported a finished install, and `zpool list` on the way out
    /// still showed rpool. bpool had exported; rpool never could.
    ///
    /// S3's step 10 is the sequence that works, and everything in it is here:
    /// sync, unmount the ESP, unmount the target recursively, `zfs umount -a`,
    /// then export **bpool before rpool**.
    ///
    /// It matters less than it looks — the installed system carries the same
    /// `/etc/hostid` the pools were created with (L13), so it would import them
    /// at boot regardless. But an unclean export is a pool ZFS has to decide
    /// about at boot rather than simply open, and "it recovers" is not the same
    /// claim as "it is correct".
    /// </summary>
    public void Run(Executor x)
    {
        x.TryExec("sync");

        // /dev, /proc, /sys and /run went away with the chroot's mount namespace
        // (BUILD-NOTES #18). Only the ESP and the ZFS mounts are left.
        x.TryExec("umount", _t.Esp);
        x.TryExec("umount", "-R", _t.Root);
        x.TryExec("zfs", "umount", "-a");

        // bpool FIRST. It lives under <target>/boot, inside rpool.
        foreach (string pool in new[] { "bpool", "rpool" })
            Export(x, pool);

        if (_plan.Storage.Encrypt)
            x.TryExec("cryptsetup", "close", StorageSteps.LuksName);

        if (x.DryRun) return;

        // Ask, rather than assume. A pool still imported here is the difference
        // between a clean first boot and one that has to recover - and it is the
        // check the first Phase 3 run did not have.
        string left = x.TryExec("zpool", "list", "-H", "-o", "name").Trim();
        if (left.Length == 0)
            Log.Info("both pools exported; the disk is no longer in use");
        else
            Log.Error($"still imported after teardown: {left.ReplaceLineEndings(" ")}");
    }

    /// <summary>
    /// Export one pool, and SAY WHAT IS HOLDING IT if it will not go.
    ///
    /// Forcing is the last resort and it is logged as a fault rather than
    /// treated as a step. S3's own comment is the right standard: "a real
    /// installer should treat this as a bug to fix, not a step to normalise".
    /// It is safe here only because everything above has already been written
    /// and synced — and note that `-f` does NOT help against a mount held in
    /// another namespace, which is what the chroot's `unshare` exists to avoid.
    /// </summary>
    private void Export(Executor x, string pool)
    {
        if (x.DryRun) { x.TryExec("zpool", "export", pool); return; }

        string before = x.TryExec("zpool", "list", "-H", "-o", "name");
        if (!before.Split('\n').Any(l => l.Trim() == pool))
        {
            Log.Info($"{pool} is not imported; nothing to export");
            return;
        }

        try
        {
            x.Exec("zpool", "export", pool);
            Log.Info($"{pool} exported");
            return;
        }
        catch (StepException ex)
        {
            Log.Warn($"{pool} would not export: {ex.Output.ReplaceLineEndings(" ")}");
        }

        // What is still holding it. Both questions S3 asks, because "pool is
        // busy" names no culprit and the two candidates need different fixes.
        Log.Warn($"still mounted below {_t}: "
                 + x.TryExec("findmnt", "-R", "-n", _t.Root).ReplaceLineEndings(" ").Trim());
        Log.Warn("processes rooted or working inside the target: "
                 + x.TryExec("bash", "-c",
                       $"ls -l /proc/*/cwd /proc/*/root 2>/dev/null | grep -- {_t} || echo none")
                    .ReplaceLineEndings(" ").Trim());

        x.TryExec("zpool", "export", "-f", pool);
        string after = x.TryExec("zpool", "list", "-H", "-o", "name");
        if (after.Split('\n').Any(l => l.Trim() == pool))
            Log.Error($"{pool} would not export even with -f");
        else
            Log.Error($"{pool} needed a FORCED export - that is a bug, not a step");
    }
}
