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

    public bool Validate(out List<string> problems)
    {
        problems = new List<string>();
        if (string.IsNullOrWhiteSpace(Language)) problems.Add("no language selected");
        if (string.IsNullOrWhiteSpace(Keyboard)) problems.Add("no keyboard layout selected");
        if (string.IsNullOrWhiteSpace(Timezone)) problems.Add("no timezone selected");
        return problems.Count == 0;
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
/// Source-generated JSON, which is what makes the plan work under NativeAOT at
/// all: the reflection-based serialiser is trimmed away and would throw at run
/// time. Spike S2 exercised exactly this path on both architectures.
/// </summary>
[JsonSourceGenerationOptions(WriteIndented = true,
                             PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
                             UseStringEnumConverter = true)]
[JsonSerializable(typeof(InstallPlan))]
internal partial class PlanJson : JsonSerializerContext;
