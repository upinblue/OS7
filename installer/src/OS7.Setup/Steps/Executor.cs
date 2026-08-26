using System.Diagnostics;
using System.Text;
using OS7.Setup.Diagnostics;

namespace OS7.Setup.Steps;

/// <summary>Something that failed, with everything an error screen needs (§3.1).</summary>
internal sealed class StepException : Exception
{
    public string Command { get; }
    public string Output { get; }

    public StepException(string summary, string command, string output)
        : base(summary)
    {
        Command = command;
        Output = output;
    }
}

internal delegate void Progress(string step, int done, int total);

/// <summary>
/// Running a list of steps, and undoing them when one fails.
///
/// SETUP-PLAN §10 Phase 2: "Failure rolls back **only** what Setup created."
/// That word is the whole design. The executor does not know how to restore a
/// disk to what it was — nothing does — so every step that creates something
/// registers how to remove THAT thing, and a failure unwinds exactly the
/// registered list in reverse. A step that ran before Setup did is not on the
/// list and is not touched.
///
/// Rollback is best-effort by construction: it runs after something has already
/// gone wrong, so a failure inside it is logged and the unwinding continues.
/// Stopping the rollback at its first problem would leave more behind, not less.
/// </summary>
internal sealed class Executor
{
    private readonly List<(string What, Action Undo)> _undo = new();
    private readonly bool _dryRun;

    public Executor(bool dryRun) => _dryRun = dryRun;

    public bool DryRun => _dryRun;

    /// <summary>Register how to remove something this run created.</summary>
    public void Created(string what, Action undo)
    {
        _undo.Add((what, undo));
        Log.Info($"created: {what}");
    }

    public void Run(IReadOnlyList<IStep> steps, Progress? progress = null)
    {
        int done = 0;

        // THE MACHINE, ONCE, BEFORE ANY OF IT. An install that dies of memory
        // leaves a log that says which command was running and nothing about
        // the conditions it was running under, so the question "was there
        // enough RAM?" ends up being answered from a photograph of the screen.
        // It was, on 2026-08-26 (BUILD-NOTES #79). One line fixes that.
        Log.Info($"machine: {Diagnostics.Memory.Summary}");

        try
        {
            foreach (IStep step in steps)
            {
                progress?.Invoke(step.Describe, done, steps.Count);
                Log.Info($"step: {step.Describe}");

                // Stopwatch and not DateTime: this is a duration, and the
                // target's clock is set by TargetIdentityStep mid-run.
                var clock = System.Diagnostics.Stopwatch.StartNew();
                long before = Diagnostics.Memory.AvailableBytes;
                step.Run(this);
                clock.Stop();
                done++;

                // WHAT THE WEIGHTS ABOVE ARE MEANT TO BE MEASURED FROM, and the
                // only record of where the memory went. Both numbers come from
                // the kernel and the clock, never from the step's own opinion.
                long after = Diagnostics.Memory.AvailableBytes;
                Log.Info($"step done: {step.Describe} after {clock.Elapsed.TotalSeconds:0.0} s"
                         + (before > 0 && after > 0
                            ? $"; MemAvailable {Diagnostics.Memory.Human(before)}"
                              + $" -> {Diagnostics.Memory.Human(after)}"
                            : ""));
            }
            progress?.Invoke("done", done, steps.Count);
        }
        catch
        {
            // BEFORE THE ROLLBACK, because the rollback runs `zpool destroy` and
            // whatever the kernel says about that is not what went wrong.
            Log.Error($"machine at the failure: {Diagnostics.Memory.Summary}");
            Diagnostics.KernelLog.LogRecent("Setup's console is quiet while it runs");
            Rollback();
            throw;
        }
    }

    private void Rollback()
    {
        if (_undo.Count == 0)
        {
            Log.Info("rollback: nothing had been created yet");
            return;
        }
        Log.Warn($"rolling back {_undo.Count} thing(s) Setup created, newest first");
        for (int i = _undo.Count - 1; i >= 0; i--)
        {
            (string what, Action undo) = _undo[i];
            try
            {
                Log.Info($"rollback: {what}");
                undo();
            }
            catch (Exception ex)
            {
                Log.Error($"rollback of '{what}' failed: {ex.Message}");
            }
        }
        _undo.Clear();
    }

    /// <summary>
    /// Run a command, or print it under --dry-run.
    ///
    /// Everything the executor does goes through here, which is what makes
    /// --dry-run honest: there is no second path that could do something the
    /// dry run did not show.
    /// </summary>
    public string Exec(string exe, params string[] args) => Exec(exe, args, allowFailure: false);

    /// <summary>For the ones whose failure is expected and meaningless —
    /// clearing a label that was not there, probing a disk that has no
    /// partitions yet.</summary>
    public string TryExec(string exe, params string[] args) => Exec(exe, args, allowFailure: true);

    /// <summary>
    /// Run a command with a SECRET on its standard input.
    ///
    /// Two things a normal Exec cannot do, and both matter for exactly one
    /// caller — turning a passphrase into a crypt hash:
    ///
    ///   * the secret never reaches argv, so it is not in `ps` output on a
    ///     machine that may have somebody watching over the operator's shoulder;
    ///   * the secret never reaches the log, which `Exec` writes the whole
    ///     command line to, and which Setup offers to export to removable media.
    ///
    /// The command line IS logged. Knowing that `openssl passwd -6 -stdin` ran
    /// is what makes the log readable; knowing what went into it is not.
    /// </summary>
    public string ExecSecret(string exe, string secret, params string[] args)
    {
        string line = $"{exe} {string.Join(' ', args)} <secret on stdin>";
        if (_dryRun)
        {
            Log.Info($"would run: {line}");
            return "";
        }
        Log.Info($"run: {line}");
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (string a in args) psi.ArgumentList.Add(a);

            using Process? p = Process.Start(psi)
                ?? throw new StepException($"{exe} did not start", line, "");
            p.StandardInput.Write(secret);
            p.StandardInput.Close();
            string outText = p.StandardOutput.ReadToEnd();
            string errText = p.StandardError.ReadToEnd();
            p.WaitForExit();
            if (p.ExitCode != 0)
                throw new StepException(
                    $"Setup could not complete a step: {exe} exited {p.ExitCode}.",
                    line, Tail(errText.Length > 0 ? errText : outText));
            return outText;
        }
        catch (StepException) { throw; }
        catch (Exception ex)
        {
            throw new StepException($"Setup could not run {exe}.", line, ex.Message);
        }
    }

    private string Exec(string exe, string[] args, bool allowFailure)
    {
        string line = $"{exe} {string.Join(' ', args)}";
        if (_dryRun)
        {
            Log.Info($"would run: {line}");
            return "";
        }
        Log.Info($"run: {line}");

        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (string a in args) psi.ArgumentList.Add(a);

            using Process? p = Process.Start(psi)
                ?? throw new StepException($"{exe} did not start", line, "");
            string outText = p.StandardOutput.ReadToEnd();
            string errText = p.StandardError.ReadToEnd();
            p.WaitForExit();

            if (p.ExitCode != 0)
            {
                if (allowFailure)
                {
                    Log.Info($"  (exit {p.ExitCode}, ignored) {errText.Trim()}");
                    return outText;
                }
                throw new StepException(
                    $"Setup could not complete a step: {exe} exited {p.ExitCode}.",
                    line,
                    Tail(errText.Length > 0 ? errText : outText));
            }
            if (errText.Trim().Length > 0) Log.Info($"  {Tail(errText)}");
            return outText;
        }
        catch (StepException) { throw; }
        catch (Exception ex)
        {
            throw new StepException($"Setup could not run {exe}.", line, ex.Message);
        }
    }

    /// <summary>
    /// The last few lines of a command's output.
    ///
    /// The error screen has room for a handful of lines and the useful ones are
    /// at the end — `zpool` says what it was doing and then why it refused.
    /// Truncating from the front keeps the "why".
    /// </summary>
    private static string Tail(string s, int lines = 8)
    {
        string[] all = s.ReplaceLineEndings("\n").TrimEnd().Split('\n');
        return all.Length <= lines ? string.Join('\n', all)
                                   : string.Join('\n', all[^lines..]);
    }

    /// <summary>
    /// Wait for udev to catch up.
    ///
    /// Not politeness. `sgdisk` returns as soon as the kernel has the new table;
    /// the `/dev/disk/by-partlabel/` symlinks the next step addresses the
    /// partitions by are created by udev afterwards. Spike S3 has the same call
    /// in the same place, and addressing partitions by GPT name rather than by
    /// `${disk}${n}` is the other half of L12's naming trap.
    /// </summary>
    public void Settle()
    {
        if (_dryRun) { Log.Info("would run: udevadm settle"); return; }
        TryExec("udevadm", "settle", "--timeout=30");
    }

    public bool WaitForDevice(string path, int seconds = 30)
    {
        if (_dryRun) { Log.Info($"would wait for {path}"); return true; }
        for (int i = 0; i < seconds * 4; i++)
        {
            if (File.Exists(path) || Directory.Exists(path)) return true;
            Thread.Sleep(250);
        }
        return false;
    }
}

internal interface IStep
{
    string Describe { get; }
    void Run(Executor x);

    /// <summary>
    /// What share of the progress bar this step is worth, relative to the
    /// others. Default 1; a step that takes twenty times as long says 20.
    ///
    /// THESE ARE ESTIMATES AND THEY ARE ALLOWED TO BE — nothing but a drawn
    /// rectangle depends on them, and a wrong weight makes the bar uneven, not
    /// the install wrong. They are here because the alternative was worse: with
    /// sixteen equal steps the bar moved in 6.25% jumps and then stood still
    /// for the several minutes `unsquashfs` and `update-initramfs` take, which
    /// is the interval during which somebody decides the machine has hung.
    ///
    /// They are estimates that can STOP being estimates. `Executor.Run` logs
    /// every step's real duration ("step done: … after 41.2 s"), so an install
    /// log off any machine is a measurement of what these should have been.
    /// Correct them from a log; do not re-derive them by reading the code.
    /// </summary>
    int Weight => 1;

    /// <summary>
    /// How far through itself this step is, 0..100 — or -1 for "cannot say",
    /// which is the honest answer for most of them and the default.
    ///
    /// A step that can genuinely count its own work overrides this and the bar
    /// uses the real number. A step that cannot gets a time-based estimate from
    /// the screen instead, which never overtakes the step's own slice — so a
    /// bar that is guessing can be slow, but it can never be a lie in the
    /// direction that matters (claiming to be past work that has not happened).
    /// </summary>
    int Percent => -1;
}
