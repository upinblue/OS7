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

    /// <summary>Screen 7 — the computer's name and its first account. Phase 3.</summary>
    public AccountPlan Account { get; set; } = new();

    /// <summary>Screens 9, 9S and 9W — the network. Phase 3b, SETUP-PLAN §7.2.</summary>
    public NetworkPlan Network { get; set; } = new();

    /// <summary>
    /// The netplan renderer, DERIVED FROM <see cref="Mode"/> and from nothing
    /// else — D14, and L24 is what it costs to get wrong.
    ///
    /// amd64-GUI keeps `network-manager`, which is installed and owns every
    /// device; amd64-headless and arm64 do not, because `InstallModeStep`'s
    /// headless path runs `apt-get autoremove -y --purge` and takes NM with it.
    ///
    /// IT MUST NOT BE A PROBE. Asking the target whether `network-manager` is
    /// installed gives a different answer depending on whether the purge has run
    /// yet, which would make an installed machine's network depend on step
    /// ordering rather than on the plan. Deriving it from a value screen 8
    /// already collected makes the answer the same however the steps are
    /// arranged — and the step order is asserted separately, in SystemSteps.For.
    /// </summary>
    [JsonIgnore]
    public string Renderer => Mode == InstallMode.Gui ? "NetworkManager" : "networkd";

    /// <summary>
    /// Everything wrong with the WHOLE plan, in one pass.
    ///
    /// EXACTLY TWO CALLERS, and they are the only two moments at which the plan
    /// really is complete: `--unattend`, and `ExecuteScreen.Start` — the front
    /// door of the executor, which is why that constructor is private. One pass
    /// rather than failing on the first problem, because §3.1's error screen
    /// shows a list and a person fixing an unattended plan file wants to fix all
    /// of it before booting again.
    ///
    /// A SCREEN MUST NOT CALL THIS, and this project has now paid for that
    /// sentence twice. §6.6 has the screens filling the plan in one at a time,
    /// so the plan is incomplete for most of the flow by design.
    ///
    ///   screen 3  called it and produced an error screen reading "no disk
    ///             selected" three screens before the disk screen exists.
    ///   screen 6  called it and produced "no user account was named" ONE screen
    ///             before the account is typed — which made screen 7 unreachable
    ///             and the error screen the only thing past the confirmation.
    ///
    /// Each screen validates what it collected; only execution validates the lot.
    ///
    /// Phase 3b added the network half here and NOWHERE ELSE, for the same
    /// reason. Screens 9, 9S and 9W each refuse only their own fields; the
    /// network is checked as a whole at the same two moments as everything else.
    /// </summary>
    public bool Validate(out List<string> problems)
    {
        problems = new List<string>();
        ValidateRegional(problems);
        Storage.Validate(problems);
        Account.Validate(problems);
        Network.Validate(problems);
        return problems.Count == 0;
    }

    /// <summary>What screen 3 collected, and nothing else.</summary>
    public bool ValidateRegional(out List<string> problems)
    {
        problems = new List<string>();
        ValidateRegional(problems);
        return problems.Count == 0;
    }

    /// <summary>
    /// What screens 3 to 5 collected — the regional half and the storage half.
    ///
    /// Screen 6's check, and the account is left out of it deliberately rather
    /// than forgotten: §3's numbering puts the destructive confirmation at 6 and
    /// the account at 7, so at the moment `F` is pressed nobody has been asked
    /// for one yet. It is the same shape as ValidateRegional and exists for the
    /// same reason — a screen may only be refused for something it could have
    /// got right.
    ///
    /// It covers everything the format is about to act on, which is the whole
    /// of the storage half; the regional half rides along because screen 6 is
    /// still a screen ESC can walk back from, so a bad locale is worth saying
    /// here rather than after an account has been typed.
    /// </summary>
    public bool ValidateThroughStorage(out List<string> problems)
    {
        problems = new List<string>();
        ValidateRegional(problems);
        Storage.Validate(problems);
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

/// <summary>
/// Screen 7 — the computer's name, and the account that will run it.
///
/// SETUP-PLAN §3: Win2k asked for these in its GUI phase and OS/7 has no GUI
/// phase, so they are collected in text. NT 3.x did the same and it is not a
/// problem; it is only why the screen list is longer than Win2k's text phase.
/// </summary>
internal sealed class AccountPlan
{
    /// <summary>The machine's name. Goes to /etc/hostname and /etc/hosts.</summary>
    public string Hostname { get; set; } = "os7";

    /// <summary>The first account. In `sudo`, because otherwise nobody can
    /// administer the machine and the only other account is root.</summary>
    public string Username { get; set; } = "";

    /// <summary>For GECOS. Optional, and blank is not an error.</summary>
    public string FullName { get; set; } = "";

    /// <summary>
    /// NEVER SERIALISED, for the same reason the disk passphrase is not
    /// (§6.6): the plan is a file that goes into a repository, a log and a
    /// screenshot. `--unattend` takes it from `--password-file`, a separate
    /// artefact with its own handling.
    /// </summary>
    [JsonIgnore]
    public string? Password { get; set; }

    /// <summary>
    /// What a Linux account name may be, and it is checked here rather than
    /// left to `useradd` because `useradd` fails INSIDE THE CHROOT — six steps
    /// and several minutes after the screen that could have said so.
    ///
    /// The rule is `useradd`'s own (NAME_REGEX in login.defs): start with a
    /// lower-case letter or underscore, then lower-case letters, digits,
    /// underscore or hyphen, and no trailing `$` because that form is for
    /// machine accounts.
    /// </summary>
    public static bool IsValidUsername(string name) =>
        name.Length is > 0 and <= 32
        && (char.IsAsciiLetterLower(name[0]) || name[0] == '_')
        && name.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c)
                         || c == '_' || c == '-');

    /// <summary>
    /// RFC 1123 host label: letters, digits and hyphens, not starting or ending
    /// with one. Checked for the same reason as the username, plus one more —
    /// an invalid hostname does not stop the install, it produces a machine
    /// whose `/etc/hosts` does not resolve its own name and whose sudo pauses
    /// for ten seconds on every command.
    /// </summary>
    public static bool IsValidHostname(string name) =>
        name.Length is > 0 and <= 63
        && char.IsAsciiLetterOrDigit(name[0]) && char.IsAsciiLetterOrDigit(name[^1])
        && name.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');

    /// <summary>
    /// Reserved names — accounts the base system already owns.
    ///
    /// `useradd root` fails in the chroot with "user 'root' already exists",
    /// which is correct and arrives far too late. The full list is whatever is
    /// in the image's /etc/passwd; these are the ones somebody actually types.
    /// </summary>
    private static readonly string[] Taken =
        { "root", "daemon", "bin", "sys", "sync", "man", "lp", "mail", "news",
          "proxy", "www-data", "backup", "list", "irc", "nobody", "systemd-network",
          "messagebus", "sshd", "ubuntu", "admin", "adm" };

    public void Validate(List<string> problems)
    {
        if (!IsValidHostname(Hostname))
            problems.Add($"'{Hostname}' is not a valid computer name");
        if (string.IsNullOrEmpty(Username))
            problems.Add("no user account was named");
        else if (!IsValidUsername(Username))
            problems.Add($"'{Username}' is not a valid user name");
        else if (Taken.Contains(Username))
            problems.Add($"'{Username}' is a name the system already uses");
        if (string.IsNullOrEmpty(Password))
            problems.Add("the account has no password");
    }
}
