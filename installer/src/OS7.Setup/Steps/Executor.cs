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
        try
        {
            foreach (IStep step in steps)
            {
                progress?.Invoke(step.Describe, done, steps.Count);
                Log.Info($"step: {step.Describe}");
                step.Run(this);
                done++;
            }
            progress?.Invoke("done", done, steps.Count);
        }
        catch
        {
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
}
