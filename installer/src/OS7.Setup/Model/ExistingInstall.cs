using System.Diagnostics;
using OS7.Setup.Diagnostics;
using OS7.Setup.Steps;

namespace OS7.Setup.Model;

/// <summary>
/// What is already on a disk, when what is already on it is OS/7.
///
/// TWO REASONS THIS EXISTS, and the second one is why it is here in Phase 2/3
/// rather than in Phase 6 with the upgrade path it serves:
///
///   1. SAFETY. Screen 4 says "every partition on the selected disk will be
///      destroyed", and today it says that about a blank disk and about somebody
///      else's working OS/7 in exactly the same words. Win2k's text phase named
///      the installation it found before it offered to replace it.
///
///   2. IT IS WHAT AN UPGRADE NEEDS TO KNOW. SETUP-PLAN §3 screen 1 has
///      `R=Repair` — import an existing rpool and install into a NEW boot
///      environment beside the current one — and RELEASE-AND-UPDATE-PLAN §4.2 is
///      the same operation performed by `Update-OS7`. Both have to begin by
///      answering "what is on this disk, and which version is it". Measuring it
///      now means Phase 6 starts from a fact rather than from a plan to find out.
///
/// THE VERSION COMES FROM THE BOOT ENVIRONMENT NAME, not from a file. SETUP-PLAN
/// §4.4 pins the scheme as `os7_&lt;release&gt;_&lt;stamp&gt;`, and that name is in `bpool`
/// — which is deliberately NOT encrypted (§4.2, D3, because GRUB has to read it).
/// So the version of an installed system is readable without the passphrase,
/// which is the only reason this can work at all: the release manifest itself
/// lives on `rpool`, behind LUKS.
/// </summary>
internal sealed record ExistingInstall(
    string? Version,
    string? BootEnvironment,
    int BootEnvironments,
    bool Encrypted,
    string? Unreadable)
{
    /// <summary>One line for the screen.</summary>
    public string Describe() =>
        Version is not null
            ? $"OS/7 {Version}" + (BootEnvironments > 1 ? $", {BootEnvironments} boot environments" : "")
            : $"OS/7, version unreadable ({Unreadable ?? "no boot environment found"})";
}

internal static class ExistingInstalls
{
    /// <summary>
    /// The cheap tier: does this disk carry the §4.4 partition layout?
    ///
    /// GPT partition names, straight out of the lsblk call screen 4 already
    /// makes. No import, no device opened for writing, nothing that can fail —
    /// so it can run for every disk during enumeration without putting a
    /// multi-second operation on the path that draws a screen.
    ///
    /// The labels are the ones PartitionStep writes (StorageSteps.EspLabel and
    /// friends), referenced rather than repeated: a detector that spells the
    /// label differently from the creator finds nothing and says "blank disk"
    /// about an installation.
    /// </summary>
    public static bool LooksLikeOs7(LsblkDevice disk)
    {
        if (disk.Children is null) return false;
        bool bpool = false, luks = false;
        foreach (LsblkDevice c in disk.Children)
        {
            if (c.PartLabel == StorageSteps.BpoolLabel) bpool = true;
            if (c.PartLabel == StorageSteps.LuksLabel) luks = true;
        }
        // bpool alone is enough to identify the layout, and it is the partition
        // the version can be read from. LUKS only decides whether to say
        // "encrypted"; requiring both would miss an unencrypted install, which
        // the plan permits even though the default is on.
        return bpool || luks;
    }

    /// <summary>
    /// The version tier: import `bpool` READ-ONLY and UNMOUNTED, read the boot
    /// environment names out of it, export it again.
    ///
    /// Every part of that sentence is load-bearing:
    ///
    ///   -o readonly=on   nothing is written to the pool, including the label
    ///                    update that a plain `-f` import performs.
    ///   -N               do not mount anything. BUILD-NOTES #18 is about a pool
    ///                    that would not export because something was mounted
    ///                    from it; with -N there is nothing to unmount, and the
    ///                    export at the end cannot be the thing that fails.
    ///   -f               the pool was created on ANOTHER machine, so its hostid
    ///                    will not match this live medium's and an import without
    ///                    -f refuses with "previously in use from another
    ///                    system". -f is what makes that case readable, and
    ///                    readonly=on is what makes -f harmless.
    ///   -R               an altroot, so even a mistake cannot land on /.
    ///   -d <partition>   look at THIS disk, not at every pool on the machine.
    ///                    Without it, a second disk's bpool answers for the first.
    ///
    /// Run only for a disk <see cref="LooksLikeOs7"/> already matched, and only
    /// when the operator has selected it — this is seconds of work, not
    /// microseconds, and screen 4 must not stall while it enumerates.
    ///
    /// VERIFIED 2026-08-24 against a disk this installer made.
    /// `installer/testing/run-phase2.py existing` installs OS/7 unattended,
    /// reboots, points Setup at that same disk and reads the answer off the
    /// screen: "vdb already carries OS/7 1.0.0.32". So the read-only import
    /// argument above is no longer only a reading of zpool(8) — the pool was
    /// imported, listed and exported on a real disk, and the install that
    /// followed it worked.
    /// </summary>
    public static ExistingInstall? Probe(Disk disk)
    {
        string bpoolPart = PartitionWithLabel(disk, StorageSteps.BpoolLabel);
        bool encrypted = PartitionWithLabel(disk, StorageSteps.LuksLabel).Length > 0;

        if (bpoolPart.Length == 0)
        {
            // A LUKS container and no boot pool. It is an OS/7 layout - or was -
            // but the half carrying the version is not there.
            return encrypted
                ? new ExistingInstall(null, null, 0, true, "no boot pool on this disk")
                : null;
        }

        const string altroot = "/run/os7-probe";
        bool imported = false;
        try
        {
            Directory.CreateDirectory(altroot);

            (int code, string outp, string err) =
                Run("zpool", 60, "import", "-f", "-N", "-o", "readonly=on",
                    "-R", altroot, "-d", bpoolPart, "bpool");
            if (code != 0)
            {
                string why = Firstline(err.Length > 0 ? err : outp);
                Log.Warn($"probing {disk.Name}: bpool would not import: {why}");
                return new ExistingInstall(null, null, 0, encrypted, why);
            }
            imported = true;

            (int lc, string list, string lerr) =
                Run("zfs", 30, "list", "-H", "-o", "name", "-d", "1", "bpool/BOOT");
            if (lc != 0)
            {
                Log.Warn($"probing {disk.Name}: bpool/BOOT unreadable: {Firstline(lerr)}");
                return new ExistingInstall(null, null, 0, encrypted, "no bpool/BOOT dataset");
            }

            // `zfs list -d 1` includes the container itself; the boot
            // environments are its children.
            var names = new List<string>();
            foreach (string line in list.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                string n = line.Trim();
                if (n.Length == 0 || n == "bpool/BOOT") continue;
                names.Add(n[(n.LastIndexOf('/') + 1)..]);
            }
            if (names.Count == 0)
                return new ExistingInstall(null, null, 0, encrypted, "no boot environment");

            // Newest last: the stamp is yyyyMMddHHmm, so ordinal sort IS
            // chronological order - which is the reason §4.4 chose that format
            // over anything with separators in it.
            names.Sort(StringComparer.Ordinal);
            string newest = names[^1];
            return new ExistingInstall(VersionOf(newest), newest, names.Count, encrypted, null);
        }
        catch (Exception ex)
        {
            Log.Warn($"probing {disk.Name} failed: {ex.Message}");
            return new ExistingInstall(null, null, 0, encrypted, ex.Message);
        }
        finally
        {
            // ALWAYS, including after an exception. A bpool left imported is a
            // bpool the install cannot destroy three screens later, and the
            // failure would surface as "zpool create: device is in use" with
            // nothing pointing back at a probe that ran before the operator had
            // decided anything.
            if (imported)
            {
                (int ec, _, string eerr) = Run("zpool", 60, "export", "bpool");
                if (ec != 0) Log.Error($"probe could not export bpool: {Firstline(eerr)}");
            }
            try { Directory.Delete(altroot); } catch { /* it may not be empty; harmless */ }
        }
    }

    /// <summary>
    /// `os7_1.0.0.32_202608241419` -> `1.0.0.32`.
    ///
    /// Parsed from the middle field rather than by a regular expression, because
    /// the release string is allowed to contain anything §3.3's four fields plus
    /// the module's own sanitising produce, and pinning a pattern here would
    /// silently stop recognising a version the module happily writes.
    /// </summary>
    public static string? VersionOf(string bootEnvironment)
    {
        string[] parts = bootEnvironment.Split('_');
        // name_release_stamp: exactly three, and the last has to be the stamp.
        if (parts.Length != 3 || parts[0] != "os7") return null;
        if (parts[2].Length != 12 || !parts[2].All(char.IsAsciiDigit)) return null;
        return parts[1].Length == 0 ? null : parts[1];
    }

    private static string PartitionWithLabel(Disk disk, string label)
    {
        foreach (var (path, l) in disk.PartitionLabels)
            if (l == label) return path;
        return "";
    }

    private static string Firstline(string s)
    {
        foreach (string line in s.Split('\n'))
            if (line.Trim().Length > 0) return line.Trim();
        return "no output";
    }

    private static (int, string, string) Run(string exe, int seconds, params string[] args)
    {
        var psi = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string a in args) psi.ArgumentList.Add(a);

        using Process? p = Process.Start(psi);
        if (p is null) return (127, "", $"{exe} did not start");

        string outp = p.StandardOutput.ReadToEnd();
        string err = p.StandardError.ReadToEnd();

        // A DEADLINE, because this runs while somebody is looking at a screen.
        // `zpool import` scanning a disk that is failing can sit there for
        // minutes, and a frozen installer is indistinguishable from a crashed
        // one to the person in front of it.
        if (!p.WaitForExit(seconds * 1000))
        {
            try { p.Kill(entireProcessTree: true); } catch { /* already gone */ }
            return (124, outp, $"{exe} did not finish within {seconds}s");
        }
        return (p.ExitCode, outp, err);
    }
}
