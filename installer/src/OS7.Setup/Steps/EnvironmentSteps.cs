using OS7.Setup.Diagnostics;

namespace OS7.Setup.Steps;

/// <summary>
/// The first step of every install: what this machine has, and a ceiling on the
/// one thing Setup is about to make grow without one.
///
/// BUILD-NOTES #79. An amd64 install in a 6 GB VM reached the pool step and the
/// kernel started killing processes. Three things were true at once and all
/// three were measured out of the shipped image afterwards rather than guessed:
/// the Install boot entry started a full Ubuntu desktop's background workload
/// (`unattended-upgrades`, six `snapd` units, `packagekit`, `apt-daily.timer`
/// and fourteen more timers); the root a live medium writes to is RAM and there
/// is no swap behind it; and the ZFS ARC had no limit, so it takes half of
/// physical memory by default. The first is fixed on the medium
/// (`os7-setup-quiesce`, the generator), the second cannot be fixed, and the
/// THIRD IS THIS STEP.
///
/// It creates nothing, so it registers no rollback. It also never fails the
/// install: a ceiling that could not be applied is a machine that is more
/// likely to run out of memory, not a machine that must not be installed. Every
/// outcome is logged, including the one where nothing happened.
/// </summary>
internal sealed class InstallerEnvironmentStep : IStep
{
    public string Describe => "Preparing the installer environment";

    /// <summary>Where the running kernel keeps the ARC ceiling, in bytes.</summary>
    public const string ArcMaxPath = "/sys/module/zfs/parameters/zfs_arc_max";

    /// <summary>
    /// An installer's share of memory for caching ZFS, and the reasoning is
    /// the whole of it: Setup writes several gigabytes ONCE, reads almost
    /// nothing back, and then reboots. A read cache has nothing to give it.
    ///
    /// An eighth of the machine, never below 128 MiB (below `zfs_arc_min` the
    /// kernel refuses the write outright) and never above 1 GiB (a 64 GB
    /// machine has no more use for a big ARC here than a 6 GB one does).
    /// The default this replaces is HALF of physical memory.
    /// </summary>
    public const long FloorBytes = 128L * 1024 * 1024;
    public const long CeilingBytes = 1024L * 1024 * 1024;

    public static long WantedArcMax(long memTotalBytes)
    {
        if (memTotalBytes <= 0) return FloorBytes;
        return Math.Clamp(memTotalBytes / 8, FloorBytes, CeilingBytes);
    }

    /// <summary>
    /// Under this, an install is being attempted on a machine that has less
    /// memory than the medium it booted from needs to stay alive. It is a
    /// WARNING and not a refusal, because the real floor has never been
    /// measured — refusing on a number nobody has established would stop
    /// installs that would have worked. SETUP-PLAN L33.
    /// </summary>
    public const long LowMemoryWarnBytes = 4L * 1024 * 1024 * 1024;

    public void Run(Executor x)
    {
        long total = Memory.TotalBytes;
        Log.Info($"installer environment: {Memory.Summary}");

        // THE CONFIGURED SIZE AND THE SIZE THE GUEST SEES ARE DIFFERENT NUMBERS.
        // Under Hyper-V Dynamic Memory a VM created with 6 GB boots with its
        // startup allocation and grows only if the guest onlines what the
        // balloon hot-adds. MemTotal is what the kernel will actually hand out,
        // so MemTotal is what is written down.
        if (total > 0 && total < LowMemoryWarnBytes)
            Log.Warn($"this machine reports {Memory.Human(total)} of memory. "
                     + "OS/7 Setup writes to a RAM-backed root with no swap; "
                     + "below 4 GiB the kernel may kill processes mid-install. "
                     + "If this is a virtual machine, check that it was given "
                     + "the memory it was configured with.");

        if (Memory.SwapTotalBytes == 0)
            Log.Info("no swap, as expected on a setup medium: every allocation "
                     + "here has to fit in RAM");

        CapArc(x, total);
    }

    /// <summary>
    /// Lower the ARC ceiling, then ASK THE KERNEL WHAT IT IS.
    ///
    /// The write is the diagnostic's own subject, so it does not get to report
    /// on itself: `zfs_arc_max` has a setter in the module that clamps and can
    /// reject, and a successful `write(2)` means the call returned, not that
    /// the ceiling moved. The value that goes into the log is the one read back
    /// out of sysfs afterwards.
    /// </summary>
    private static void CapArc(Executor x, long total)
    {
        long want = WantedArcMax(total);

        if (x.DryRun)
        {
            Log.Info($"would cap the ZFS ARC at {Memory.Human(want)} "
                     + $"(writing {want} to {ArcMaxPath})");
            return;
        }

        if (!File.Exists(ArcMaxPath))
        {
            // The module is loaded by zfs-load-module.service on this medium,
            // but the pools are created by the NEXT steps and the ceiling is
            // worth nothing after the ARC has already grown. Load it here so
            // the limit is in place before the first byte of ZFS I/O.
            Log.Info($"{ArcMaxPath} is not there yet; loading the ZFS module");
            x.TryExec("modprobe", "zfs");
        }
        if (!File.Exists(ArcMaxPath))
        {
            Log.Warn($"{ArcMaxPath} does not exist — the ARC keeps its default "
                     + "ceiling of half of physical memory");
            return;
        }

        long was = ReadArcMax();
        try
        {
            File.WriteAllText(ArcMaxPath, want.ToString());
        }
        catch (Exception ex)
        {
            Log.Warn($"could not write {ArcMaxPath}: {ex.Message}");
        }

        long now = ReadArcMax();
        if (now == want)
            Log.Info($"ZFS ARC ceiling {Describe0(was)} -> {Memory.Human(now)}"
                     + $" ({now} bytes), read back from {ArcMaxPath}");
        else
            Log.Warn($"asked for an ARC ceiling of {Memory.Human(want)}; "
                     + $"{ArcMaxPath} reads {Describe0(now)}. The install "
                     + "continues with whatever the kernel decided.");
    }

    private static string Describe0(long v) =>
        v == 0 ? "0 (the default: half of physical memory)" : Memory.Human(v);

    private static long ReadArcMax()
    {
        try { return long.TryParse(File.ReadAllText(ArcMaxPath).Trim(), out long v) ? v : -1; }
        catch { return -1; }
    }
}
