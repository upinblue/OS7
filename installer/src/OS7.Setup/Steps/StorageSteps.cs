using System.Diagnostics;
using System.Text;
using OS7.Setup.Diagnostics;
using OS7.Setup.Model;

namespace OS7.Setup.Steps;

/// <summary>
/// The storage sequence, in the order spike S3 proved.
///
/// `installer/spikes/s3-zfs-luks.sh` is the evidence that this layout boots at
/// all, and SETUP-PLAN §10 says the executor "should be a front-end over
/// exactly this sequence, not a re-derivation". So the ORDER here is S3's, and
/// every place where the order matters carries S3's reason for it.
///
/// One deliberate divergence, and §11 names it: S3 predates D10 and creates
/// `rpool/ROOT/$BE/var` and `/var/log` as children of the boot environment.
/// §4.4 now splits them. The dataset hierarchy therefore comes from
/// `New-OS7Storage` in the OS7 PowerShell module, not from S3 — and from there
/// rather than from C# because `Update-OS7` needs the identical logic and
/// writing it twice guarantees drift (§6.3).
/// </summary>
internal static class StorageSteps
{
    /// <summary>Where the pools are assembled. NOT /mnt: whatever carries the
    /// installer is usually mounted there and usually read-only, so ZFS cannot
    /// create its mountpoints underneath. /target is what d-i and subiquity use
    /// for the same reason.</summary>
    public const string Target = "/target";

    public const string LuksName = "os7_root";
    public const string EspLabel = "os7-esp";
    public const string BpoolLabel = "os7-bpool";
    public const string LuksLabel = "os7-luks";

    public static string EspPath => $"/dev/disk/by-partlabel/{EspLabel}";
    public static string BpoolPath => $"/dev/disk/by-partlabel/{BpoolLabel}";
    public static string LuksPath => $"/dev/disk/by-partlabel/{LuksLabel}";
    public static string MapperPath => $"/dev/mapper/{LuksName}";

    public static List<IStep> For(InstallPlan plan) => new()
    {
        new HostIdStep(),
        new PartitionStep(plan.Storage),
        new EspStep(plan.Storage),
        new LuksStep(plan.Storage),
        new PoolsAndDatasetsStep(plan),
    };
}

// ---------------------------------------------------------------------------
internal sealed class HostIdStep : IStep
{
    public string Describe => "Generating the host identifier";

    /// <summary>
    /// L13, and the single most expensive ZFS-root footgun there is.
    ///
    /// A pool records the hostid of whoever last imported it. If the installed
    /// system's hostid does not match, the pool refuses to import at boot and
    /// the machine lands in the initramfs.
    ///
    /// The ordering that makes it safe, and it is the reason this step is FIRST:
    /// generate the hostid on the LIVE system, create the pools under it, then
    /// copy that exact file into the target (Phase 3). Doing it the other way
    /// round — zgenhostid into the target at the end — leaves the pools stamped
    /// with whatever the live system happened to have.
    /// </summary>
    public void Run(Executor x)
    {
        const string path = "/etc/hostid";
        if (!x.DryRun && File.Exists(path) && new FileInfo(path).Length > 0)
        {
            Log.Info($"{path} already exists; the pools will be stamped with it");
            return;
        }
        x.Exec("zgenhostid", "-f");
    }
}

// ---------------------------------------------------------------------------
internal sealed class PartitionStep : IStep
{
    private readonly StoragePlan _plan;

    public PartitionStep(StoragePlan plan) => _plan = plan;

    public string Describe => $"Partitioning {_plan.Disk}";

    public void Run(Executor x)
    {
        string disk = _plan.Disk!;

        // Stale ZFS labels on a reused disk make `zpool create` refuse or, worse,
        // resurrect a phantom pool (L12). Clear the whole-disk label and every
        // partition's, because either can carry one.
        x.TryExec("zpool", "labelclear", "-f", disk);
        foreach (string part in PartitionsOf(disk))
            x.TryExec("zpool", "labelclear", "-f", part);

        x.TryExec("wipefs", "-a", disk);
        x.Exec("sgdisk", "--zap-all", disk);

        // Sizes come from the plan, but the TYPES and NAMES do not: EF00 is what
        // firmware looks for, BF00 is Solaris/ZFS, 8309 is LUKS, and the names
        // are what the next steps address the partitions by.
        x.Exec("sgdisk", $"-n1:1M:+{_plan.EfiMiB}M", "-t1:EF00", $"-c1:{StorageSteps.EspLabel}", disk);
        x.Exec("sgdisk", $"-n2:0:+{_plan.BpoolGiB}G", "-t2:BF00", $"-c2:{StorageSteps.BpoolLabel}", disk);
        x.Exec("sgdisk", "-n3:0:0", "-t3:8309", $"-c3:{StorageSteps.LuksLabel}", disk);

        // The partition table is Setup's, so Setup knows how to remove it. This
        // is the only rollback that touches the disk itself, and it is honest:
        // it does not pretend to restore what was there, it removes what Setup
        // put there.
        x.Created($"the partition table on {disk}",
                  () => x.TryExec("sgdisk", "--zap-all", disk));

        x.TryExec("partprobe", disk);
        x.Settle();

        // Addressed by GPT name, never by "${disk}${n}" - /dev/vdb1 vs
        // /dev/nvme0n1p1 vs /dev/mmcblk0p1 is exactly L12's naming trap.
        foreach (string want in new[] { StorageSteps.EspPath, StorageSteps.BpoolPath, StorageSteps.LuksPath })
            if (!x.WaitForDevice(want))
                throw new StepException(
                    "Setup partitioned the disk, but the partitions did not appear.",
                    $"sgdisk … {disk}",
                    $"{want} was still missing 30 seconds after partprobe and udevadm settle.");
    }

    /// <summary>Existing partitions of a disk, by walking /sys/block.</summary>
    private static IEnumerable<string> PartitionsOf(string disk)
    {
        string name;
        try
        {
            // The plan carries a by-id symlink; /sys/block is keyed by the
            // kernel name behind it.
            name = Path.GetFileName(File.ResolveLinkTarget(disk, true)?.FullName ?? disk);
        }
        catch
        {
            name = Path.GetFileName(disk);
        }
        string dir = $"/sys/block/{name}";
        if (!Directory.Exists(dir)) yield break;
        foreach (string sub in Directory.EnumerateDirectories(dir, name + "*"))
            yield return "/dev/" + Path.GetFileName(sub);
    }
}

// ---------------------------------------------------------------------------
internal sealed class EspStep : IStep
{
    private readonly StoragePlan _plan;

    public EspStep(StoragePlan plan) => _plan = plan;

    public string Describe => "Creating the EFI system partition";

    /// <summary>
    /// FAT32, and there is no configuration in which this goes away on a UEFI
    /// machine: firmware can only read FAT from the ESP. That is the UEFI
    /// specification, not a Linux limitation (L1, §4.1).
    /// </summary>
    public void Run(Executor x) =>
        x.Exec("mkfs.vfat", "-F32", "-n", "OS7ESP", StorageSteps.EspPath);
}

// ---------------------------------------------------------------------------
internal sealed class LuksStep : IStep
{
    private readonly StoragePlan _plan;

    public LuksStep(StoragePlan plan) => _plan = plan;

    public string Describe => _plan.Encrypt
        ? "Creating the encrypted container"
        : "Skipping encryption (not requested)";

    public void Run(Executor x)
    {
        if (!_plan.Encrypt)
        {
            Log.Warn("encryption is OFF — Intune's Require Device Encryption rule "
                     + "will fail on this machine (§4.5)");
            return;
        }

        // A keyfile in /run, which is a tmpfs: the passphrase never touches a
        // disk, and it is removed before this method returns whatever happens.
        string keyfile = "/run/os7-setup.key";
        try
        {
            if (!x.DryRun)
            {
                // NO TRAILING NEWLINE. `luksFormat` consumes the keyfile
                // verbatim while the boot prompt strips the newline, so a file
                // written with `echo` means the passphrase typed at install time
                // is not the one that unlocks at boot. S3 found this and it is
                // the kind of bug that only shows up on the second reboot.
                File.WriteAllBytes(keyfile, Encoding.UTF8.GetBytes(_plan.Passphrase!));
                File.SetUnixFileMode(keyfile, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }

            // Explicit, modest PBKDF cost. The default targets a wall-clock time
            // and sizes memory from the LIVE system's RAM; the initramfs has to
            // reproduce it at boot on the same machine but with far less memory
            // available. Pinning it makes install-time and boot-time agree.
            x.Exec("cryptsetup", "luksFormat", StorageSteps.LuksPath, keyfile,
                   "--type", "luks2", "--batch-mode",
                   "--label", "OS7ROOT",
                   "--pbkdf", "argon2id", "--pbkdf-memory", "524288",
                   "--pbkdf-parallel", "2", "--iter-time", "2000");

            // --allow-discards --persistent writes the discard flag into the
            // LUKS2 header, so it also applies to the unlock the initramfs does
            // at boot. Without TRIM reaching the SSD, ZFS autotrim is silently a
            // no-op and the drive quietly loses write endurance (§4.5).
            x.Exec("cryptsetup", "open", "--key-file", keyfile,
                   "--allow-discards", "--persistent",
                   StorageSteps.LuksPath, StorageSteps.LuksName);

            x.Created($"the LUKS mapping {StorageSteps.LuksName}",
                      () => x.TryExec("cryptsetup", "close", StorageSteps.LuksName));

            if (!x.WaitForDevice(StorageSteps.MapperPath))
                throw new StepException(
                    "Setup created the encrypted container, but it did not open.",
                    $"cryptsetup open … {StorageSteps.LuksName}",
                    $"{StorageSteps.MapperPath} did not appear.");
        }
        finally
        {
            try { if (File.Exists(keyfile)) File.Delete(keyfile); }
            catch (Exception ex) { Log.Warn($"could not remove {keyfile}: {ex.Message}"); }
        }
    }
}

// ---------------------------------------------------------------------------
internal sealed class PoolsAndDatasetsStep : IStep
{
    private readonly InstallPlan _plan;

    public PoolsAndDatasetsStep(InstallPlan plan) => _plan = plan;

    public string Describe => "Creating the ZFS pools and datasets";

    public string? BootEnvironment { get; private set; }

    /// <summary>
    /// Out to PowerShell, and §6.3 is the reason.
    ///
    /// `Update-OS7` and `Restore-OS7` need boot-environment creation and
    /// rollback; Setup needs the identical logic for the first one. It lives
    /// once, in the OS7 module, and Setup invokes it out-of-process — not
    /// Microsoft.PowerShell.SDK hosted in-process, which is large and
    /// reflection-heavy and which NativeAOT cannot have.
    ///
    /// The module writes progress to stderr and exactly one JSON object to
    /// stdout, so the two can be read apart.
    ///
    /// AND IT PASSES `-UserName`, which is BUILD-NOTES #74 and the reason this
    /// comment exists. The module creates `rpool/USERDATA/&lt;name&gt;_&lt;suffix&gt;` at
    /// `/home/&lt;name&gt;`, and until 2026-08-26 the name it used was the module's
    /// own default — `os7` — because this command string carried four arguments
    /// and not five. The account is created six steps later by `useradd -m`
    /// under whatever the operator typed, so every machine this repository has
    /// installed came out with an empty dataset at `/home/os7` and the real
    /// home an ordinary directory inside the boot environment. `Restore-OS7`
    /// then rolls a user's files back with the system, which is exactly what
    /// §4.4 puts USERDATA outside ROOT to prevent.
    ///
    /// THE NAME IS AVAILABLE HERE, and that is the whole fix. `InstallPlan` is
    /// validated as a whole before the executor starts — `ExecuteScreen.Start`
    /// and `--unattend` are its only two callers — so by the time any storage
    /// step runs, `plan.Account.Username` has been through
    /// `AccountPlan.IsValidUsername`. It is not a violation of #45's rule
    /// (a screen validates only what IT collected): this is not a screen, it is
    /// the executor, and the executor's contract is a complete plan.
    /// </summary>
    public void Run(Executor x)
    {
        string device = _plan.Storage.Encrypt ? StorageSteps.MapperPath : StorageSteps.LuksPath;
        string be = ReadBootEnvironmentName(x);
        BootEnvironment = be;

        if (!x.DryRun) Directory.CreateDirectory(StorageSteps.Target);

        string script =
            "Import-Module /usr/local/share/powershell/Modules/OS7/OS7.psd1 -Force; " +
            "New-OS7Storage " +
            $"-Root '{StorageSteps.Target}' " +
            $"-RootDevice '{device}' " +
            $"-BootDevice '{StorageSteps.BpoolPath}' " +
            $"-BootEnvironment '{be}' " +
            UserNameArgument() +
            (x.DryRun ? "-WhatIf" : "-Confirm:$false");

        // Registered BEFORE the call, not after: if New-OS7Storage fails halfway
        // it may already have created bpool, and a rollback that only knows
        // about pools the call REPORTED would leave that one behind. Destroying
        // a pool that does not exist is a no-op.
        x.Created("the ZFS pools",
                  () =>
                  {
                      x.TryExec("zpool", "destroy", "-f", "rpool");
                      x.TryExec("zpool", "destroy", "-f", "bpool");
                  });

        string json = RunPwsh(x, script);
        if (!x.DryRun && json.Length > 0) Log.Info($"New-OS7Storage: {json.Trim()}");
    }

    /// <summary>
    /// `-UserName '&lt;account&gt;' ` — or nothing at all, and the empty case is a
    /// decision rather than a fallback.
    ///
    /// `--storage-only` stops before an account exists (Program.cs: it
    /// validates `plan.Storage` alone, deliberately), so there is no name to
    /// pass. The module's answer to that is to create NO home dataset and to
    /// say so in its result — not to invent one. A dataset named after a
    /// default is what #74 was.
    ///
    /// An invalid name here would be a plan that reached the executor without
    /// being validated, which cannot happen through either caller — so it is a
    /// bug in Setup rather than a bad answer from an operator, and it stops the
    /// install BEFORE the disk is touched rather than producing a machine whose
    /// home is in the wrong place. The name is also the last defence for the
    /// single-quoted PowerShell string it lands in.
    /// </summary>
    private string UserNameArgument()
    {
        string name = _plan.Account.Username;
        if (string.IsNullOrEmpty(name))
        {
            Log.Info("no account is named in this plan (--storage-only): "
                     + "New-OS7Storage will create no home dataset");
            return "";
        }
        if (!AccountPlan.IsValidUsername(name))
            throw new StepException(
                "Setup cannot create the storage layout for this account.",
                "New-OS7Storage -UserName",
                $"'{name}' is not a valid account name and reached the executor anyway. "
                + "The plan should have been refused before the disk was touched.");
        Log.Info($"the home dataset will be /home/{name}");
        return $"-UserName '{name}' ";
    }

    private string ReadBootEnvironmentName(Executor x)
    {
        // The scheme is pinned in §4.4 and lives in the module, because
        // Restore-OS7 has to list and sort by it. Asking the module rather than
        // formatting it here is the same anti-drift argument as the rest.
        string script =
            "Import-Module /usr/local/share/powershell/Modules/OS7/OS7.psd1 -Force; " +
            "New-OS7BootEnvironmentName";
        string name = RunPwsh(x, script).Trim();
        if (name.Length > 0 && !name.Contains(' ')) return name;

        // A dry run does not start PowerShell, so there is no name to have. The
        // fallback is deliberately the module's own "no release" value rather
        // than a plausible-looking one, so a dry run never shows a version
        // number that came from nowhere.
        name = $"os7_0.0.0.0_{DateTime.Now:yyyyMMddHHmm}";
        if (x.DryRun) Log.Info($"dry run: assuming the boot environment would be {name}");
        else Log.Warn($"the module returned no boot-environment name; using {name}");
        return name;
    }

    private static string RunPwsh(Executor x, string script)
    {
        string line = $"pwsh -NoProfile -Command <{script.Length} chars>";
        if (x.DryRun)
        {
            // A DRY RUN RUNS NOTHING, including this. Passing -WhatIf into the
            // module would be the other choice and it is worse: it starts a
            // process, imports a module and depends on pwsh being installed, so
            // `--dry-run` would fail on a machine where the real run would have
            // worked for a completely different reason. The commands the module
            // would issue are in OS7.psm1, next to why each one is what it is.
            Log.Info($"would run: {line}");
            return "";
        }
        Log.Info($"run: {line}");

        try
        {
            var psi = new ProcessStartInfo("pwsh")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-NonInteractive");
            psi.ArgumentList.Add("-Command");
            psi.ArgumentList.Add(script);

            using Process? p = Process.Start(psi)
                ?? throw new StepException("Setup could not start PowerShell.", line, "");

            string outText = p.StandardOutput.ReadToEnd();
            string errText = p.StandardError.ReadToEnd();
            p.WaitForExit();

            // stderr is the module's progress channel, so it is logged even on
            // success - it is the only record of which zpool command ran.
            foreach (string l in errText.ReplaceLineEndings("\n").Split('\n'))
                if (l.Trim().Length > 0) Log.Info($"  {l.TrimEnd()}");

            if (p.ExitCode != 0)
                throw new StepException(
                    "Setup could not create the ZFS pools and datasets.",
                    "pwsh -NoProfile -Command 'New-OS7Storage …'",
                    errText.Trim().Length > 0 ? errText.Trim() : outText.Trim());

            return outText;
        }
        catch (StepException) { throw; }
        catch (Exception ex)
        {
            throw new StepException("Setup could not run PowerShell.", line, ex.Message);
        }
    }
}
