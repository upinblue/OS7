using System.Text;
using OS7.Setup.Diagnostics;

namespace OS7.Setup.Steps;

/// <summary>
/// The filesystem Setup is building, and how to run something inside it.
///
/// THIS TYPE EXISTS BECAUSE THE ROOT IS A PARAMETER, NOT A CONSTANT — and that
/// is a decision, taken 2026-08-24, not a refactoring.
///
/// RELEASE-AND-UPDATE-PLAN §4.2 describes `Update-OS7` as the same sequence
/// Setup runs, from step 3 onwards, against a CLONED boot environment mounted
/// somewhere else: "everything from 3 onward is S3 code with a different root".
/// SETUP-PLAN §6.3 already routes the ZFS work through the OS7 module for
/// exactly that reason. Phase 3 is where the rest of that sequence gets written,
/// so it is the last moment at which the root can be made a parameter for free.
/// Hard-coding `/target` here would mean writing every chroot step a second time
/// for the update path, and re-validating all of Phase 3 to do it.
///
/// So: no step below reaches for `StorageSteps.Target`. They take a TargetRoot.
/// </summary>
internal sealed class TargetRoot
{
    /// <summary>Where the boot environment is mounted.</summary>
    public string Root { get; }

    public TargetRoot(string root) => Root = root.TrimEnd('/');

    /// <summary>An install into the pools Phase 2 created at their altroot.</summary>
    public static TargetRoot Install => new(StorageSteps.Target);

    /// <summary>A path inside the target. `At("etc/fstab")` -> `/target/etc/fstab`.</summary>
    public string At(string relative) => $"{Root}/{relative.TrimStart('/')}";

    /// <summary>Where the ESP is mounted inside the target.</summary>
    public string Esp => At("boot/efi");

    public override string ToString() => Root;

    // -----------------------------------------------------------------------
    // Writing files into the target
    // -----------------------------------------------------------------------

    /// <summary>
    /// Write a file inside the target, creating its directory.
    ///
    /// Text goes in with LF endings and no BOM. Every file written here is read
    /// by something that parses lines — crypttab, fstab, os-release, a systemd
    /// unit — and a BOM in the first of those is a first line that does not
    /// match anything, silently.
    /// </summary>
    public void Write(Executor x, string relative, string content, string mode = "0644")
    {
        string path = At(relative);
        if (x.DryRun)
        {
            Log.Info($"would write {path} ({content.Length} chars, mode {mode})");
            return;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content.ReplaceLineEndings("\n"), new UTF8Encoding(false));
        x.Exec("chmod", mode, path);
        Log.Info($"wrote {path} ({content.Length} chars, mode {mode})");
    }

    /// <summary>Read a file out of the target, or null. For checking what was written.</summary>
    public string? Read(string relative)
    {
        try
        {
            string path = At(relative);
            return File.Exists(path) ? File.ReadAllText(path) : null;
        }
        catch (Exception ex)
        {
            Log.Warn($"could not read {At(relative)}: {ex.Message}");
            return null;
        }
    }

    // -----------------------------------------------------------------------
    // Running things inside the target
    // -----------------------------------------------------------------------

    /// <summary>
    /// Run a script inside the target, chrooted, in a PRIVATE MOUNT NAMESPACE.
    ///
    /// The namespace is BUILD-NOTES #18 and it is not tidiness. The incantation
    /// every ZFS-root guide uses — `mount --make-private --rbind` — makes the new
    /// mount private AFTER the fact, by which time it has already propagated to
    /// every peer of the live system's shared root, including namespaces
    /// belonging to systemd services. Unmounting here then leaves copies alive
    /// in theirs, and the pool will not export:
    ///
    ///     cannot export 'rpool': pool is busy
    ///
    /// with nothing visible under the target and `-f` powerless. A private
    /// namespace never propagates in the first place, and every mount in it
    /// disappears when it exits — there is no teardown to get wrong.
    ///
    /// The script is written into the target's /tmp rather than passed on a
    /// command line: these scripts contain heredocs, quoting and passwords, and
    /// `bash -c "$(escaping nightmare)"` is how an installer ends up writing a
    /// literal `$` into somebody's crypttab.
    /// </summary>
    public string Chroot(Executor x, string what, string script)
    {
        string inner = $"/tmp/os7-setup-{Environment.ProcessId}.sh";
        string wrapper = $"/run/os7-setup-wrap-{Environment.ProcessId}.sh";

        string body = $"""
            #!/bin/bash
            set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive
            export PATH=/usr/sbin:/usr/bin:/sbin:/bin
            {script}
            """;

        string wrap = $"""
            #!/bin/bash
            set -euo pipefail
            mount --rbind /dev  {Root}/dev
            mount --rbind /proc {Root}/proc
            mount --rbind /sys  {Root}/sys
            mount -t tmpfs tmpfs {Root}/run
            mkdir -p {Root}/run/lock
            exec chroot {Root} bash {inner}
            """;

        if (x.DryRun)
        {
            Log.Info($"would chroot into {Root} for: {what}");
            foreach (string line in script.Split('\n'))
                if (line.Trim().Length > 0) Log.Info($"    | {line.TrimEnd()}");
            return "";
        }

        Directory.CreateDirectory(At("tmp"));
        File.WriteAllText(At(inner), body.ReplaceLineEndings("\n"));
        File.WriteAllText(wrapper, wrap.ReplaceLineEndings("\n"));
        try
        {
            string output = x.Exec("unshare", "--mount", "--propagation", "private",
                                   "--", "bash", wrapper);

            // THE SCRIPT'S OUTPUT IS THE ONLY PLACE ITS PROOFS EXIST, so it is
            // logged rather than returned and dropped.
            //
            // Every chroot script in this codebase ends by checking its own work
            // and saying what it found — AccountStep reads the hash length out of
            // /etc/shadow, InitramfsStep lists what the initrd contains,
            // NetworkStep reads back the unit netplan generated. `Executor.Exec`
            // captures stdout and never prints it, so until now all of that went
            // into a string that nobody looked at: the steps proved their work
            // to an empty room.
            //
            // Found on 2026-08-25 by a harness assertion that watched the serial
            // console for a line the console structurally could not carry. The
            // assertion was wrong; the gap it revealed was not.
            //
            // The scripts print no secrets — hashes and passphrases are in the
            // script text, which is logged only under --dry-run, never in what
            // the script says back.
            foreach (string line in output.Split('\n'))
                if (line.Trim().Length > 0) Log.Info($"    {what}: {line.TrimEnd()}");
            return output;
        }
        finally
        {
            // The script may carry a password hash. It is removed whether the
            // chroot succeeded or not, and before anything else can read it.
            try { File.Delete(At(inner)); } catch { /* the pool may be gone */ }
            try { File.Delete(wrapper); } catch { /* ditto */ }
        }
    }
}
