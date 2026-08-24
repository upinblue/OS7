using System.Text.Json;
using System.Text.Json.Serialization;

namespace OS7.Setup.Model;

/// <summary>
/// What Setup is going to do, as data.
///
/// SETUP-PLAN §6.6: every interactive screen only edits this object, and
/// execution happens strictly afterwards from this object alone. Three things
/// fall out of that for free — `--unattend plan.json`, `--dry-run --print-plan`,
/// and a CI run that installs OS/7 in QEMU and asserts the result, which is the
/// only affordable way to keep an installer honest.
///
/// Phase 1 fills in the regional half and the intent. The storage half is
/// Phase 2 and the account half is Phase 3; they are absent rather than stubbed,
/// so that a plan file from this phase cannot look like it says something about
/// a disk.
/// </summary>
internal sealed class InstallPlan
{
    /// <summary>Bumped when a field changes meaning, not when one is added.</summary>
    public int Version { get; set; } = 1;

    public Intent Intent { get; set; } = Intent.Install;

    public string Language { get; set; } = "en_US.UTF-8";
    public string Keyboard { get; set; } = "us";
    public string Timezone { get; set; } = "UTC";

    /// <summary>
    /// GUI or headless, and amd64-only as a question (README: arm64 is
    /// server-only, so there is nothing to ask there). Screen 8, Phase 3.
    /// </summary>
    public InstallMode Mode { get; set; } = InstallMode.Headless;

    public StoragePlan Storage { get; set; } = new();

    /// <summary>
    /// Everything wrong with the WHOLE plan, in one pass.
    ///
    /// For `--unattend` and for the moment before execution — the two places
    /// where the plan really is complete. One pass rather than failing on the
    /// first problem, because §3.1's error screen shows a list and a person
    /// fixing an unattended plan file wants to fix all of it before booting
    /// again.
    ///
    /// A SCREEN MUST NOT CALL THIS. §6.6 has the screens filling the plan in
    /// one at a time, so the plan is incomplete for most of the flow by design.
    /// Screen 3 did call it, and the result was an error screen reading "no disk
    /// selected" three screens before the disk screen exists. Each screen
    /// validates what it collected; only execution validates the lot.
    /// </summary>
    public bool Validate(out List<string> problems)
    {
        problems = new List<string>();
        ValidateRegional(problems);
        Storage.Validate(problems);
        return problems.Count == 0;
    }

    /// <summary>What screen 3 collected, and nothing else.</summary>
    public bool ValidateRegional(out List<string> problems)
    {
        problems = new List<string>();
        ValidateRegional(problems);
        return problems.Count == 0;
    }

    private void ValidateRegional(List<string> problems)
    {
        if (string.IsNullOrWhiteSpace(Language)) problems.Add("no language selected");
        if (string.IsNullOrWhiteSpace(Keyboard)) problems.Add("no keyboard layout selected");
        if (string.IsNullOrWhiteSpace(Timezone)) problems.Add("no timezone selected");
    }

    public string ToJson() => JsonSerializer.Serialize(this, PlanJson.Default.InstallPlan);

    public static InstallPlan? FromJson(string json) =>
        JsonSerializer.Deserialize(json, PlanJson.Default.InstallPlan);
}

internal enum Intent
{
    /// <summary>Screen 1, ENTER — a fresh install.</summary>
    Install,

    /// <summary>
    /// Screen 1, R. Win2k's Repair maps almost exactly onto a ZFS concept:
    /// import an existing rpool and install into a NEW boot environment beside
    /// the current one, leaving rpool/USERDATA untouched. Phase 6.
    /// </summary>
    Repair,
}

internal enum InstallMode { Gui, Headless }

/// <summary>
/// The storage half of the plan — SETUP-PLAN §4.4 and §4.5.
///
/// Sizes are in MiB and GiB as whole numbers because that is how they are typed
/// into `sgdisk`, and a plan file that says 512 is a plan file a person can read.
/// </summary>
internal sealed class StoragePlan
{
    /// <summary>
    /// The target, as a STABLE path — `/dev/disk/by-id/…` where one exists.
    ///
    /// Not `/dev/sdb`. §6.6 makes the plan a file that can be written on one
    /// machine and replayed on another, and kernel device names are assigned in
    /// probe order. L12 names the same trap from the other direction.
    /// </summary>
    public string? Disk { get; set; }

    /// <summary>Single disk for v1. Mirrors need one LUKS container per member
    /// (§4.5) and are not implemented.</summary>
    public string Layout { get; set; } = "single";

    /// <summary>512 MiB, FAT32, and not negotiable: UEFI firmware reads FAT from
    /// the ESP and that is the specification, not a Linux limitation (L1).</summary>
    public int EfiMiB { get; set; } = 512;

    /// <summary>GRUB reads ZFS read-only, so /boot is its own unencrypted pool
    /// (D1, §4.2). 2 GiB holds several kernels and their initramfs.</summary>
    public int BpoolGiB { get; set; } = 2;

    /// <summary>LUKS2 under ZFS, never ZFS native (D3). Off is allowed on
    /// servers, where Azure Arc has no encryption compliance rule — but the code
    /// path is the same one, so there is one test matrix (§4.5).</summary>
    public bool Encrypt { get; set; } = true;

    /// <summary>zram by default: swap on a zvol still deadlocks upstream, so
    /// swap is never on ZFS (D4).</summary>
    public string Swap { get; set; } = "zram";

    /// <summary>
    /// NEVER SERIALISED, and that is the point of the attribute rather than a
    /// convention.
    ///
    /// §6.6 makes the plan a file — `--print-plan` writes it, `--unattend` reads
    /// it, and CI will keep one in a repository. A passphrase in that file is a
    /// passphrase in a log, in a screenshot and in a git history. Unattended
    /// installs take it from `--passphrase-file` instead, which is a separate
    /// artefact with its own handling.
    /// </summary>
    [JsonIgnore]
    public string? Passphrase { get; set; }

    public void Validate(List<string> problems)
    {
        if (string.IsNullOrWhiteSpace(Disk)) problems.Add("no disk selected");
        if (Layout != "single") problems.Add($"layout '{Layout}' is not implemented (single only)");
        if (EfiMiB < 256) problems.Add($"the EFI partition is too small at {EfiMiB} MiB");
        if (BpoolGiB < 1) problems.Add($"the boot pool is too small at {BpoolGiB} GiB");
        if (Swap != "zram") problems.Add($"swap '{Swap}' is not implemented (zram only)");
        if (Encrypt && string.IsNullOrEmpty(Passphrase))
            problems.Add("encryption is on but no passphrase was given");
    }
}

/// <summary>
/// Source-generated JSON, which is what makes the plan work under NativeAOT at
/// all: the reflection-based serialiser is trimmed away and would throw at run
/// time. Spike S2 exercised exactly this path on both architectures.
/// </summary>
[JsonSourceGenerationOptions(WriteIndented = true,
                             PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
                             UseStringEnumConverter = true)]
[JsonSerializable(typeof(InstallPlan))]
internal partial class PlanJson : JsonSerializerContext;
