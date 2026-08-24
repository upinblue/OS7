using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using OS7.Setup.Diagnostics;

namespace OS7.Setup.Model;

/// <summary>
/// One block device Setup might install to — and, when it may not, why.
///
/// `Blocker` being non-null is the whole safety model of screen 4: a disk that
/// cannot be used is still LISTED, with the reason next to it. L12 requires
/// the setup medium to be shown and never selectable, and the same shape covers
/// every other refusal. Hiding a disk makes Setup look broken to whoever is
/// staring at the machine that has it.
/// </summary>
internal sealed record Disk(
    string Path,
    string StablePath,
    string Name,
    long Bytes,
    string Model,
    string Serial,
    string PartitionTable,
    int Partitions,
    string? Blocker,
    IReadOnlyList<(string Path, string Label)> PartitionLabels,
    bool Os7Layout)
{
    public bool Selectable => Blocker is null;

    /// <summary>GB as a person reads them, i.e. 10^9 — the number on the label.</summary>
    public string Size => Bytes >= 1_000_000_000_000L
        ? $"{Bytes / 1e12:0.##} TB"
        : $"{Bytes / 1e9:0.##} GB";

    /// <summary>What screen 4 puts in the box, in the §3.1 column layout.</summary>
    public string Describe(int width)
    {
        // "OS/7 installation" outranks the partition count, because the count is
        // what a blank GPT disk and somebody's working system have in common and
        // the distinction is the one that matters before ENTER is pressed. The
        // VERSION is not here: reading it costs an import, and screen 4 lists
        // every disk on the machine (DiskScreen.Handle probes the one chosen).
        string what = Blocker is not null ? $"-- {Blocker.ToUpperInvariant()} --"
            : Os7Layout ? "OS/7 installation"
            : PartitionTable.Length == 0 ? "empty"
            : $"{PartitionTable.ToUpperInvariant()}, {Partitions} partition{(Partitions == 1 ? "" : "s")}";
        string model = Model.Length > 0 ? Model : "(no model)";
        // Columns rather than a sentence, because the eye scans a list of disks
        // by column and §3.1's mockup is drawn that way.
        string s = $"{Name,-10}{Truncate(model, 26),-27}{Size,9}   {what}";
        return s.Length > width ? s[..width] : s;
    }

    private static string Truncate(string s, int n) => s.Length <= n ? s : s[..n];
}

/// <summary>
/// Finding the disks, and refusing the ones Setup must not touch.
///
/// SETUP-PLAN §6.2 puts this on "C# reading /sys/block, /dev/disk/by-id, plus
/// lsblk --json" — lsblk because it already knows about partition tables,
/// mount points and device types, and re-deriving that from sysfs is how a
/// installer ends up with its own half-right model of a disk.
/// </summary>
internal static class Disks
{
    /// <summary>
    /// Where casper mounts the medium it booted from. Checked as MOUNT POINTS
    /// rather than by device name, because the medium is a CD on one machine, a
    /// USB stick on the next, and a virtio-blk device in a VM — and L12's naming
    /// trap (`/dev/vdb1` vs `/dev/nvme0n1p1` vs `/dev/mmcblk0p1`) is exactly
    /// what makes name-matching wrong.
    /// </summary>
    private static readonly string[] MediumMounts =
        { "/cdrom", "/run/live/medium", "/isodevice", "/media/cdrom", "/lib/live/mount/medium" };

    public static List<Disk> Enumerate()
    {
        LsblkRoot? tree = RunLsblk();
        if (tree?.BlockDevices is null)
        {
            Log.Error("lsblk returned nothing usable; no disks can be offered");
            return new List<Disk>();
        }

        var disks = new List<Disk>();
        foreach (LsblkDevice d in tree.BlockDevices)
        {
            if (d.Type != "disk") continue;                 // loop, rom, part, md…
            if (d.Name is null || d.Path is null) continue;

            // zram and ramdisks are "disks" to lsblk and are not somewhere an
            // operating system can live.
            if (d.Name.StartsWith("zram", StringComparison.Ordinal) ||
                d.Name.StartsWith("ram", StringComparison.Ordinal)) continue;

            string? blocker = Blocked(d);
            int parts = d.Children?.Count(c => c.Type == "part") ?? 0;

            var labels = new List<(string, string)>();
            if (d.Children is not null)
                foreach (LsblkDevice c in d.Children)
                    if (c.Type == "part" && c.Path is not null &&
                        !string.IsNullOrEmpty(c.PartLabel))
                        labels.Add((c.Path, c.PartLabel));

            disks.Add(new Disk(
                Path: d.Path,
                StablePath: StablePath(d.Name, d.Path),
                Name: d.Name,
                Bytes: d.Size ?? 0,
                Model: (d.Model ?? "").Trim(),
                Serial: (d.Serial ?? "").Trim(),
                PartitionTable: d.PtType ?? "",
                Partitions: parts,
                Blocker: blocker,
                PartitionLabels: labels,
                Os7Layout: ExistingInstalls.LooksLikeOs7(d)));
        }

        disks.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));
        foreach (Disk d in disks)
            Log.Info($"disk {d.Name} {d.Size} {d.Model} "
                     + (d.Blocker is null ? "selectable" : $"BLOCKED: {d.Blocker}")
                     + (d.Os7Layout ? " CARRIES AN OS/7 LAYOUT" : "")
                     + $" [{d.StablePath}]");
        return disks;
    }

    private static string? Blocked(LsblkDevice d)
    {
        // THE MEDIUM CHECK COMES FIRST, and the order is the point rather than a
        // preference. A boot medium is often also read-only — an ISO attached
        // read-only, a write-protected stick — and reporting "read-only" for it
        // is true, useless, and wrong on the case that matters: a real USB stick
        // is writable, so the read-only check would not fire and the medium
        // check is the only thing standing between Setup and eating the
        // installer it is running from (L12).
        if (Mounted(d, MediumMounts)) return "setup medium";

        if (d.ReadOnly == true) return "read-only";

        // Anything else that is mounted. Not necessarily fatal in principle, but
        // an installer that partitions a disk out from under a mounted
        // filesystem is an installer that corrupts whatever was using it, and
        // "unmount it yourself first" is an instruction a person can act on.
        string? mount = AnyMount(d);
        if (mount is not null) return $"in use at {mount}";

        if ((d.Size ?? 0) < MinimumBytes)
            return $"too small (needs {MinimumBytes / 1_000_000_000} GB)";

        return null;
    }

    // ESP + bpool + something to install into. 16 GB is not a recommendation,
    // it is the floor below which the layout in §4.4 cannot be laid down at all.
    private const long MinimumBytes = 16L * 1000 * 1000 * 1000;

    private static bool Mounted(LsblkDevice d, string[] points)
    {
        foreach (string? m in Walk(d))
            if (m is not null && points.Any(p => m == p || m.StartsWith(p + "/", StringComparison.Ordinal)))
                return true;
        return false;
    }

    private static string? AnyMount(LsblkDevice d)
    {
        foreach (string? m in Walk(d))
            if (!string.IsNullOrEmpty(m) && m != "[SWAP]") return m;
        return null;
    }

    private static IEnumerable<string?> Walk(LsblkDevice d)
    {
        if (d.MountPoints is not null)
            foreach (string? m in d.MountPoints) yield return m;
        if (d.Children is null) yield break;
        foreach (LsblkDevice c in d.Children)
            foreach (string? m in Walk(c)) yield return m;
    }

    /// <summary>
    /// A name that survives a reboot and a re-enumeration.
    ///
    /// The plan stores this rather than /dev/sdb, because §6.6 makes the plan a
    /// file that can be written on one machine and replayed on another, and
    /// kernel device names are assigned in probe order. by-id is preferred over
    /// by-path for the same reason: by-path changes when the disk moves slot.
    ///
    /// wwn- and nvme-eui. ids are skipped when anything else is available -
    /// they are stable but they say nothing to a person reading the plan file.
    /// </summary>
    private static string StablePath(string name, string fallback)
    {
        try
        {
            const string dir = "/dev/disk/by-id";
            if (!Directory.Exists(dir)) return fallback;
            var links = new List<string>();
            foreach (string link in Directory.EnumerateFileSystemEntries(dir))
            {
                // Resolved to the FINAL target, because by-id entries point at
                // /dev/<name> through a relative "../../<name>" link and the
                // question is which kernel device this is, not how it is spelt.
                string? target = File.ResolveLinkTarget(link, returnFinalTarget: true)?.Name;
                if (target == name) links.Add(link);
            }
            if (links.Count == 0) return fallback;
            links.Sort((a, b) => Rank(a).CompareTo(Rank(b)));
            return links[0];
        }
        catch (Exception ex)
        {
            Log.Warn($"resolving a stable name for {name} failed: {ex.Message}");
            return fallback;
        }

        static int Rank(string path)
        {
            string b = Path.GetFileName(path);
            if (b.StartsWith("wwn-", StringComparison.Ordinal)) return 2;
            if (b.StartsWith("nvme-eui.", StringComparison.Ordinal)) return 2;
            return 1;
        }
    }

    private static LsblkRoot? RunLsblk()
    {
        try
        {
            var psi = new ProcessStartInfo("lsblk")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            // -b: bytes, not "931.5G" - a size that has to be parsed back out of
            // a human string is a size that will be parsed wrong eventually.
            foreach (string a in new[]
                     {
                         "--json", "-b", "-o",
                         // PARTLABEL is what identifies an existing OS/7 install:
                         // PartitionStep writes os7-esp / os7-bpool / os7-luks as
                         // GPT partition names, and reading them back costs one
                         // more column on a call screen 4 already makes.
                         "NAME,PATH,TYPE,SIZE,MODEL,SERIAL,RO,RM,PTTYPE,PARTLABEL,MOUNTPOINTS,TRAN",
                     })
                psi.ArgumentList.Add(a);

            using Process? p = Process.Start(psi);
            if (p is null) { Log.Error("lsblk did not start"); return null; }
            string json = p.StandardOutput.ReadToEnd();
            string err = p.StandardError.ReadToEnd();
            p.WaitForExit();
            if (p.ExitCode != 0)
            {
                Log.Error($"lsblk exited {p.ExitCode}: {err.Trim()}");
                return null;
            }
            return JsonSerializer.Deserialize(json, LsblkJson.Default.LsblkRoot);
        }
        catch (Exception ex)
        {
            Log.Error($"lsblk failed: {ex.Message}");
            return null;
        }
    }
}

// ---------------------------------------------------------------------------
// lsblk's JSON, only the fields Setup asked for.
//
// Source-generated, like the install plan: under NativeAOT the reflection
// serialiser is trimmed away and would throw at run time (spike S2).
// ---------------------------------------------------------------------------
internal sealed class LsblkRoot
{
    [JsonPropertyName("blockdevices")]
    public List<LsblkDevice>? BlockDevices { get; set; }
}

internal sealed class LsblkDevice
{
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("path")] public string? Path { get; set; }
    [JsonPropertyName("type")] public string? Type { get; set; }
    [JsonPropertyName("size")] public long? Size { get; set; }
    [JsonPropertyName("model")] public string? Model { get; set; }
    [JsonPropertyName("serial")] public string? Serial { get; set; }
    [JsonPropertyName("ro")] public bool? ReadOnly { get; set; }
    [JsonPropertyName("rm")] public bool? Removable { get; set; }
    [JsonPropertyName("pttype")] public string? PtType { get; set; }
    [JsonPropertyName("partlabel")] public string? PartLabel { get; set; }
    [JsonPropertyName("tran")] public string? Transport { get; set; }
    [JsonPropertyName("mountpoints")] public List<string?>? MountPoints { get; set; }
    [JsonPropertyName("children")] public List<LsblkDevice>? Children { get; set; }
}

[JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(LsblkRoot))]
internal partial class LsblkJson : JsonSerializerContext;
