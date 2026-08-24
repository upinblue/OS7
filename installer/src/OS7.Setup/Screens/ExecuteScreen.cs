using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Steps;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

/// <summary>
/// Screens 10 and 11 — the install, running, with a progress bar.
///
/// ONE SCREEN OBJECT FOR TWO NUMBERED SCREENS, and the reason is mechanical
/// rather than a shortcut. §3.1 draws "Copying files" and "Configuring the
/// system" separately, and they ARE separate to look at — the first has a
/// filename scrolling under the bar and the second does not. But they are one
/// Executor run on one worker thread, and a second Screen object would have to
/// attach to a thread already in flight and hand the rollback list between them.
/// The heading and the detail line follow the step instead, so the two mockups
/// both appear and neither is a separate machine.
///
/// The work runs on a BACKGROUND THREAD and the screen only reads a snapshot of
/// where it has got to. That is not concurrency for its own sake: the flow's
/// input loop wakes every 200 ms whether or not a key arrived (Input.Read's idle
/// tick), so a screen that changes on its own repaints for free — and an
/// executor called inline would freeze the console for the length of a
/// `cryptsetup luksFormat`, which is seconds of a machine that looks hung.
/// </summary>
internal sealed class ExecuteScreen : Screen
{
    private readonly InstallPlan _plan;
    private readonly List<IStep> _steps;
    private readonly Executor _executor;
    private readonly Thread _worker;

    private readonly object _gate = new();
    private string _current = "Starting";
    private int _done;
    private bool _finished;
    private StepException? _failure;
    private Exception? _crash;

    /// <summary>
    /// Set once from --dry-run, before the flow starts.
    ///
    /// Static because the screen is constructed by the Confirm screen, deep in
    /// the flow, and threading a boolean through four screens that have no other
    /// use for it would be worse than one clearly-named global that is written
    /// exactly once.
    /// </summary>
    public static bool DryRun { get; set; }

    private readonly TargetRoot _target;

    public ExecuteScreen(InstallPlan plan)
    {
        _plan = plan;
        _target = TargetRoot.Install;
        // Phase 2's storage AND Phase 3's system, as ONE list on ONE executor.
        // Two runs would each roll back only their own half, and the half left
        // behind is the one holding the disk (SystemSteps.Everything).
        _steps = SystemSteps.Everything(plan, _target);
        _executor = new Executor(DryRun);
        _worker = new Thread(Work) { IsBackground = true, Name = "os7-install" };
        _worker.Start();
    }

    private void Work()
    {
        try
        {
            _executor.Run(_steps, (step, done, total) =>
            {
                lock (_gate) { _current = step; _done = done; }
            });
            lock (_gate) { _finished = true; _done = _steps.Count; }
            Log.Info("install: done");
        }
        catch (StepException ex)
        {
            lock (_gate) { _failure = ex; _finished = true; }
            Log.Error($"install failed: {ex.Message}");
        }
        catch (Exception ex)
        {
            lock (_gate) { _crash = ex; _finished = true; }
            Log.Error($"install crashed: {ex}");
        }
    }

    public override bool Ticks => true;

    public override string Status => "Please wait...";

    public override void Draw(Frame f)
    {
        string current;
        int done;
        bool finished;
        lock (_gate) { current = _current; done = _done; finished = _finished; }

        // WHICH SCREEN THIS IS, decided by the step that is running. The copy
        // is the long one and the one §3.1 gives its own mockup to; everything
        // after it is "configuring".
        bool copying = _steps.Count > done && _steps[Math.Min(done, _steps.Count - 1)]
                       is UnsquashfsStep;
        f.Body(6, 11, copying
            ? "Setup is copying files to the OS/7 boot environment."
            : finished ? "Setup is finishing."
            : "Setup is configuring the system.");

        int barLeft = f.Left + 11;
        const int barWidth = 52;
        f.Box(9, barLeft, barWidth, 3);

        // The copy gets its OWN percentage, from unsquashfs's own output.
        //
        // Counting steps would have this bar sit at one twelfth for the several
        // minutes the copy takes, which is the interval during which somebody
        // decides the installer has hung. UnsquashfsStep publishes what it has
        // written; this reads it and scales it into that step's slice of the
        // whole, so the bar never goes backwards.
        int percent;
        if (_steps.Count == 0) percent = 100;
        else if (copying)
        {
            int slice = 100 / _steps.Count;
            percent = done * 100 / _steps.Count + slice * UnsquashfsStep.Percent / 100;
        }
        else percent = done * 100 / _steps.Count;
        percent = Math.Clamp(percent, 0, 100);
        int filled = (barWidth - 2) * percent / 100;
        for (int i = 0; i < barWidth - 2; i++)
        {
            bool on = i < filled;
            // The brand blue as a FOREGROUND - the only place in §3.1 where it
            // is one, and the reason BUILD-NOTES #30 exists.
            f.Put(10, barLeft + 1 + i, on ? '█' : ' ',
                  on ? Slot.Brand : Slot.Field, Slot.Field);
        }
        string pct = $"{percent}%";
        f.Text(12, barLeft + (barWidth - pct.Length) / 2, pct);

        f.Body(14, 11, finished ? "Finishing…" : current + "…");

        // §3.1's screen 10 has the file being written under the bar. It is not
        // decoration: it is the only thing on the screen that moves while a
        // multi-minute copy runs, and a still screen is a hung screen.
        if (copying)
        {
            string file = UnsquashfsStep.Current;
            int room = Math.Min(58, f.BodyWidth - 22);
            if (file.Length > room) file = "…" + file[^(room - 1)..];
            f.Body(15, 11, ("Copying:  " + file).PadRight(Math.Max(0, room + 10)));
        }

        f.Body(17, 11, "Do not turn off the computer.", Slot.Brand);
    }

    /// <summary>
    /// Keys are ignored while it runs — there is nothing to press. The
    /// transition happens on the idle tick instead, which is why this returns a
    /// real transition for Key.None rather than Stay.
    /// </summary>
    public override Transition Handle(KeyPress key)
    {
        lock (_gate)
        {
            if (!_finished) return Transition.Stay;
            if (_failure is not null)
                return Transition.To(ErrorScreen.ForCommand(
                    _failure.Message, _failure.Command, _failure.Output));
            if (_crash is not null)
                return Transition.To(ErrorScreen.ForException(_crash));
        }
        return Transition.To(new CompleteScreen(_plan));
    }

    /// <summary>True once the worker has stopped, however it stopped.</summary>
    public bool Finished { get { lock (_gate) return _finished; } }
}
