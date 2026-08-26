using System.Diagnostics;

namespace OS7.Setup.Diagnostics;

/// <summary>
/// What the KERNEL has to say, put where Setup's own record can carry it.
///
/// Two things made this necessary at once (BUILD-NOTES #79). The kernel's
/// complaints — "Out of memory: Killed process …", "task systemd:1 blocked for
/// more than 122 seconds" — were the only evidence of why an install died, and
/// they arrived by painting themselves across Setup's screen, which is both
/// unreadable and destroys the only other thing on it. Setup now takes the
/// console away from the kernel (see Terminal), and that would have thrown the
/// evidence away with the noise if this did not exist: the ring buffer still
/// has every line, so on a failure Setup goes and reads it.
///
/// NOTHING HERE MAY THROW. It runs inside the executor's catch block, where an
/// exception of its own would replace the real failure with a diagnostic's
/// failure — the worst possible trade.
/// </summary>
internal static class KernelLog
{
    /// <summary>
    /// The kernel's error-and-worse lines, most recent last, or "" if they
    /// cannot be had. `dmesg` and not /dev/kmsg: reading the character device
    /// blocks at the end of the buffer unless it was opened O_NONBLOCK, which
    /// needs interop, and util-linux is on every image this runs on anyway.
    /// </summary>
    public static string Recent(int lines = 12)
    {
        try
        {
            var psi = new ProcessStartInfo("dmesg")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (string a in new[] { "--level=emerg,alert,crit,err,warn", "--notime" })
                psi.ArgumentList.Add(a);

            using Process? p = Process.Start(psi);
            if (p is null) return "";
            string text = p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            if (!p.WaitForExit(5000)) return "";
            if (p.ExitCode != 0) return "";

            string[] all = text.ReplaceLineEndings("\n").TrimEnd().Split('\n');
            if (all.Length == 1 && all[0].Length == 0) return "";
            return string.Join('\n', all[Math.Max(0, all.Length - lines)..]);
        }
        catch
        {
            // Deliberately silent. This is called from a failure path; a log
            // line about the diagnostic would push the actual failure further
            // up the screen for no gain.
            return "";
        }
    }

    /// <summary>
    /// Put the kernel's last words in the log, under a heading that says whose
    /// they are. Nothing at all when the kernel had nothing to say — an empty
    /// section reads like an answer.
    /// </summary>
    public static void LogRecent(string why)
    {
        string text = Recent();
        if (text.Length == 0) return;
        Log.Warn($"the kernel's own messages ({why}):");
        foreach (string line in text.Split('\n'))
            Log.Warn($"  kernel: {line}");
    }
}
