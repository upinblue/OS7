namespace OS7.Setup.Diagnostics;

/// <summary>
/// What the machine actually has, asked of the kernel rather than assumed.
///
/// THIS EXISTS BECAUSE AN INSTALL DIED AND NOTHING IN THE RECORD SAID WHY.
/// On 2026-08-26 an amd64 install in a 6 GB Hyper-V VM reached
/// `PoolsAndDatasetsStep` and the kernel began killing processes —
/// `networkd-dispatcher`, then `unattended-upgrades` — and then blocked
/// `systemd:1` for 122 seconds. The install log recorded every command Setup
/// ran and not one number about the machine it was running on, so "was it
/// memory?" could only be answered by looking at a photograph of the screen.
/// BUILD-NOTES #79.
///
/// Every figure here is one line of `/proc/meminfo`. Nothing is derived from
/// the plan, from the image or from what a VM was configured with — the
/// configured size and the size the guest SEES are different numbers under a
/// balloon driver, and the second one is the one that OOMs.
/// </summary>
internal static class Memory
{
    public const string MemInfo = "/proc/meminfo";

    /// <summary>Physical memory the kernel is managing, in bytes; 0 if unknown.</summary>
    public static long TotalBytes => Field("MemTotal");

    /// <summary>
    /// What could be allocated without swapping, in bytes; 0 if unknown.
    ///
    /// MemAvailable and not MemFree, and the difference is the whole point on a
    /// live medium: the squashfs page cache is most of MemFree's absence and is
    /// reclaimable, while the casper overlay's tmpfs is not. MemAvailable is the
    /// kernel's own estimate of the difference, which is a better answer than
    /// anything this file could compute.
    /// </summary>
    public static long AvailableBytes => Field("MemAvailable");

    /// <summary>Swap, in bytes. A live medium has none, and that is the point.</summary>
    public static long SwapTotalBytes => Field("SwapTotal");

    /// <summary>Memory held by tmpfs — on a live medium, the writable root.</summary>
    public static long ShmemBytes => Field("Shmem");

    /// <summary>
    /// One line of /proc/meminfo in bytes, or 0 when the file or the key is not
    /// there. Zero rather than an exception: this is a diagnostic, and a
    /// diagnostic that can stop an install is worse than no diagnostic.
    /// </summary>
    public static long Field(string key)
    {
        try
        {
            return Field(File.ReadLines(MemInfo), key);
        }
        catch (Exception ex)
        {
            Log.Warn($"could not read {MemInfo}: {ex.Message}");
            return 0;
        }
    }

    /// <summary>
    /// The parsing on its own, over lines from anywhere — which is what makes
    /// it checkable. `--self-test` runs in a chroot during the ISO build, where
    /// /proc/meminfo is the BUILD HOST's, so a test that read the real file
    /// would be asserting things about a machine nobody is interested in.
    /// </summary>
    public static long Field(IEnumerable<string> lines, string key)
    {
        try
        {
            foreach (string line in lines)
            {
                if (!line.StartsWith(key, StringComparison.Ordinal)) continue;
                if (line.Length <= key.Length || line[key.Length] != ':') continue;

                string[] parts = line[(key.Length + 1)..]
                    .Split(' ', StringSplitOptions.RemoveEmptyEntries
                              | StringSplitOptions.TrimEntries);
                if (parts.Length == 0 || !long.TryParse(parts[0], out long value)) return 0;

                // meminfo is kB everywhere except a handful of count fields,
                // which carry no unit. Both are handled rather than assumed.
                return parts.Length > 1 && parts[1] == "kB" ? value * 1024 : value;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"could not read {MemInfo}: {ex.Message}");
        }
        return 0;
    }

    /// <summary>"5.9 GiB", or "unknown" for 0 — for a log line a person reads.</summary>
    public static string Human(long bytes)
    {
        if (bytes <= 0) return "unknown";
        string[] units = { "B", "KiB", "MiB", "GiB", "TiB" };
        double v = bytes;
        int u = 0;
        while (v >= 1024 && u < units.Length - 1) { v /= 1024; u++; }
        return u == 0 ? $"{bytes} B" : $"{v:0.#} {units[u]}";
    }

    /// <summary>One line for the log: what this machine has, right now.</summary>
    public static string Summary =>
        $"MemTotal {Human(TotalBytes)}, MemAvailable {Human(AvailableBytes)}, "
        + $"Shmem {Human(ShmemBytes)}, SwapTotal {Human(SwapTotalBytes)}";
}
