using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Steps;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

/// <summary>
/// The storage executor, running, with a progress bar. Modelled on §3.1's
/// screen 10 — Phase 3 turns this into the real file-copy screen.
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

    public ExecuteScreen(InstallPlan plan)
    {
        _plan = plan;
        _steps = StorageSteps.For(plan);
        _executor = new Executor(DryRun);
        _worker = new Thread(Work) { IsBackground = true, Name = "os7-storage" };
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
            Log.Info("storage: done");
        }
        catch (StepException ex)
        {
            lock (_gate) { _failure = ex; _finished = true; }
            Log.Error($"storage failed: {ex.Message}");
        }
        catch (Exception ex)
        {
            lock (_gate) { _crash = ex; _finished = true; }
            Log.Error($"storage crashed: {ex}");
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

        f.Body(6, 11, _plan.Storage.Encrypt
            ? "Setup is preparing and encrypting the disk."
            : "Setup is preparing the disk.");

        int barLeft = f.Left + 11;
        const int barWidth = 52;
        f.Box(9, barLeft, barWidth, 3);
        int percent = _steps.Count == 0 ? 100 : done * 100 / _steps.Count;
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
        f.Body(16, 11, "Do not turn off the computer.", Slot.Brand);
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
