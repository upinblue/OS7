using System.Linq;
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
/// THE CONSTRUCTOR IS PRIVATE and `Start` is the only way in. Constructing this
/// object begins writing to a disk, so "did anybody check the plan first?" must
/// not be a question about the caller. `Start` asks InstallPlan.Validate and
/// hands back an error screen instead of an executor when the answer is no.
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

    // ---- the progress bar's arithmetic (§3.1's bar, BUILD-NOTES #79) -------
    //
    // WEIGHTED, AND CALIBRATED AGAINST ITSELF. Counting steps put the bar at
    // 25% for the whole of the pool step and at 31% for the several minutes of
    // the copy, in 6.25% jumps - a bar that stands still and then leaps, which
    // is exactly the shape that reads as "hung". Two changes fix it:
    //
    //   * a step's slice is its IStep.Weight, not 1/n, so a step that takes
    //     seconds gets a sliver and `unsquashfs` gets half of the bar;
    //   * inside a slice the bar keeps moving. A step that can count its own
    //     work says so (IStep.Percent); the rest get a time-based estimate.
    //
    // The estimate needs a seconds-per-weight scale and NOTHING KNOWS THAT IN
    // ADVANCE - the same install is fifteen minutes on one machine and an hour
    // on another. So it is measured during the run: once any weight has been
    // completed, the scale is the elapsed time divided by the weight behind it,
    // and the estimate for the running step follows the machine it is on.
    // The arithmetic itself is in ProgressModel, which has no thread and no
    // disk and is therefore the half of this screen that `--self-test` can
    // walk a whole simulated install through.
    private readonly ProgressModel _progress;
    private readonly System.Diagnostics.Stopwatch _clock =
        System.Diagnostics.Stopwatch.StartNew();
    private double _stepStartedAt;             // seconds on _clock

    /// <summary>
    /// Set once from --dry-run, before the flow starts.
    ///
    /// Static because the screen is constructed deep in the flow — screen 8, or
    /// screen 7 where there is no screen 8 — and threading a boolean through
    /// every screen between here and the command line, none of which has any
    /// other use for it, would be worse than one clearly-named global that is
    /// written exactly once.
    /// </summary>
    public static bool DryRun { get; set; }

    private readonly TargetRoot _target;

    /// <summary>
    /// THE FINAL GATE, and the only way to build an executor.
    ///
    /// The constructor below starts a thread that partitions a disk, so the
    /// check that the plan is complete cannot be somewhere a caller might
    /// forget: it is in front of the only door. §6.6 has execution read the plan
    /// and nothing else, and this is the moment §6.6 means — after this there is
    /// no screen left to catch an incomplete plan on, which is the sentence
    /// screen 6 used to carry while 7 and 8 still came after it.
    ///
    /// It returns an ErrorScreen rather than throwing, and ForPlan's error
    /// screen is the RECOVERABLE one: ENTER goes back to the screen that could
    /// fix it. A plan that is short of a field is a person who has not finished,
    /// not a failed install.
    ///
    /// Nothing has been written when this refuses. The executor is not
    /// constructed at all, so there is no thread, no rollback list and no disk
    /// to undo.
    /// </summary>
    public static Screen Start(InstallPlan plan)
    {
        if (!plan.Validate(out List<string> problems))
        {
            Log.Error("refusing to install: " + string.Join("; ", problems));
            return ErrorScreen.ForPlan(problems);
        }
        return new ExecuteScreen(plan);
    }

    private ExecuteScreen(InstallPlan plan)
    {
        _plan = plan;
        _target = TargetRoot.Install;
        // Phase 2's storage AND Phase 3's system, as ONE list on ONE executor.
        // Two runs would each roll back only their own half, and the half left
        // behind is the one holding the disk (SystemSteps.Everything).
        _steps = SystemSteps.Everything(plan, _target);

        _progress = new ProgressModel(_steps.Select(s => s.Weight).ToList());

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
                // The moment the slice starts, so the creep below measures from
                // it. Taken here rather than in Draw: the screen repaints on an
                // idle tick and may not run at all in the first 200 ms.
                lock (_gate)
                {
                    _current = step;
                    _done = done;
                    _stepStartedAt = _clock.Elapsed.TotalSeconds;
                }
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
        double stepStartedAt;
        lock (_gate)
        {
            current = _current; done = _done; finished = _finished;
            stepStartedAt = _stepStartedAt;
        }

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

        // The running step's own figure, or -1 where it has none. Read through
        // IStep, so "the copy" is not a special case in here any more.
        int reported = done < _steps.Count ? _steps[done].Percent : -1;
        int percent = _progress.Percent(done, finished, stepStartedAt,
                                        _clock.Elapsed.TotalSeconds, reported);
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
