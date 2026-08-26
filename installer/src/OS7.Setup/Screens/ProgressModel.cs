namespace OS7.Setup.Screens;

/// <summary>
/// Where the bar has got to — the arithmetic on its own, with no thread, no
/// executor and no disk.
///
/// SEPARATE FROM <see cref="ExecuteScreen"/> BECAUSE IT HAS TO BE CHECKABLE.
/// Constructing an ExecuteScreen starts a thread that partitions a disk, so the
/// self-test cannot make one — which for two months meant the progress bar was
/// the one part of Setup that nothing could assert anything about. It is also
/// the part a person watches for a quarter of an hour deciding whether the
/// machine has hung. This class takes weights and numbers and returns a
/// percentage; `--self-test` walks a whole simulated install through it.
///
/// It holds no clock of its own for the same reason: the caller passes the time
/// in, so a test can run an hour of install in a millisecond.
///
/// WHAT IT GUARANTEES, and all three are asserted:
///
///   * it never goes backwards, whatever the inputs do;
///   * a step's estimate never reaches into the next step's slice;
///   * it is 100 when, and only when, the run is finished.
///
/// BUILD-NOTES #79.
/// </summary>
internal sealed class ProgressModel
{
    private readonly int[] _weightBefore;   // prefix sums; [i] is the weight before step i
    private readonly int _total;
    private int _shown;

    /// <summary>
    /// The scale to use before the run has measured its own. A whole install is
    /// on the order of 200 weight and a quarter of an hour on the machines this
    /// has been run on, so about 4 s to the weight. It is replaced by a
    /// measurement as soon as the first step finishes — that is the environment
    /// step and it takes no time — so this constant is the scale for a few
    /// seconds of a fifteen-minute bar, and being wrong about it is cheap.
    /// </summary>
    public const double InitialSecondsPerWeight = 4.0;

    /// <summary>
    /// How far into its own slice a step may CREEP without evidence. The
    /// remaining tenth is what the step's completion pays for, so the bar always
    /// moves when something real happens and never claims to be past work that
    /// has not been done.
    /// </summary>
    public const double CreepCeiling = 0.90;

    /// <summary>
    /// How much of the creep is spent at a CONSTANT RATE over the step's
    /// expected duration, before the curve bends to absorb an overrun.
    ///
    /// THE SHAPE WAS CHOSEN BY MEASUREMENT AND THE FIRST TWO CANDIDATES LOST.
    /// `--self-test` walks the real step list at the screen's own 200 ms tick
    /// and reports the longest the number stands still; over the same simulated
    /// 20-minute install:
    ///
    ///     1 - e^(-t/tau), tau = duration        34 s
    ///     1 - e^(-t/tau), tau = duration/3      54 s
    ///     t / (t + duration/2)                  51 s
    ///     linear for the duration, then bend    this
    ///
    /// The two curved ones lose for the same reason, and it is not the one that
    /// was expected: their problem is the TAIL, not the climb. Both give up
    /// their rate fastest exactly where a step is overrunning — which is the
    /// moment somebody is looking at the screen wondering. Climbing faster made
    /// it worse, because it reached the flat part sooner.
    ///
    /// A constant rate has no tail to give up. Every step then advances the
    /// number at the same interval — one point per (seconds-per-weight ÷ share
    /// of the bar), about a sixth of a minute here — and the bend after the
    /// expected end is only ever reached by a step that has already outlived
    /// its estimate, where slowing down IS the honest thing to do.
    /// </summary>
    public const double LinearShare = 0.8;

    public ProgressModel(IReadOnlyList<int> weights)
    {
        _weightBefore = new int[weights.Count + 1];
        for (int i = 0; i < weights.Count; i++)
            _weightBefore[i + 1] = _weightBefore[i] + Math.Max(1, weights[i]);
        _total = Math.Max(1, _weightBefore[weights.Count]);
    }

    public int Steps => _weightBefore.Length - 1;

    /// <summary>The whole bar, 0..100, for the state described by the arguments.</summary>
    /// <param name="done">how many steps have finished; also the index of the running one</param>
    /// <param name="finished">the run has ended, however it ended</param>
    /// <param name="stepStartedAt">seconds on the run clock when the running step began</param>
    /// <param name="now">seconds on the run clock, now</param>
    /// <param name="reported">the running step's own 0..100, or -1 for "cannot say"</param>
    public int Percent(int done, bool finished, double stepStartedAt, double now, int reported)
    {
        int percent;
        if (finished || Steps == 0 || done >= Steps)
        {
            percent = 100;
        }
        else
        {
            int behind = _weightBefore[done];
            int weight = _weightBefore[done + 1] - behind;
            double within = reported >= 0
                ? Math.Clamp(reported / 100.0, 0, 1)
                : Creep(behind, weight, stepStartedAt, now);
            percent = (int)((behind + weight * within) * 100.0 / _total);
        }

        percent = Math.Clamp(percent, 0, 100);

        // THE ONE PROPERTY A PROGRESS BAR HAS TO HAVE. A weighted estimate is
        // exactly the thing that would otherwise break it: a step that finishes
        // sooner than the creep expected would hand the next step a smaller
        // starting figure than the bar is already showing.
        if (percent < _shown) percent = _shown;
        _shown = percent;
        return percent;
    }

    /// <summary>
    /// The estimate for a step that cannot count its own work: a constant rate
    /// over the duration the weights expect, then a bend, scaled to
    /// CreepCeiling so it approaches the end of the slice and never arrives.
    ///
    /// TAU IS MEASURED, NOT DECLARED. The same install is a quarter of an hour
    /// on one machine and an hour on another, so the seconds-per-weight scale
    /// comes from the run itself: the time the completed steps actually took,
    /// over the weight they were worth. A slow machine gets a slow creep
    /// automatically, and nothing has to know what hardware it is on.
    /// </summary>
    private static double Creep(int behind, int weight, double stepStartedAt, double now)
    {
        double secondsPerWeight = behind > 0 && stepStartedAt > 0
            ? stepStartedAt / behind
            : InitialSecondsPerWeight;

        // A run whose first steps were instant would otherwise divide by almost
        // nothing and creep to the ceiling in one frame; one that paused for an
        // hour would stop moving altogether.
        secondsPerWeight = Math.Clamp(secondsPerWeight, 0.25, 60.0);

        double elapsed = Math.Max(0, now - stepStartedAt);
        double expected = Math.Max(0.2, weight * secondsPerWeight);
        double u = elapsed / expected;

        // Straight up to LinearShare over the expected duration, then a
        // hyperbolic that spends the rest of the ceiling over the overrun and
        // never arrives. The two halves meet at u = 1 with the same value, so
        // the bar does not step at the join.
        double shape = u <= 1
            ? LinearShare * u
            : LinearShare + (1 - LinearShare) * (u - 1) / u;
        return CreepCeiling * shape;
    }
}
