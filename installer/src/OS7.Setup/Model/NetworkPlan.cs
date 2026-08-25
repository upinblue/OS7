using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Serialization;

namespace OS7.Setup.Model;

internal enum NetworkMethod
{
    /// <summary>Take an address from the network. The default everywhere else.</summary>
    Dhcp,

    /// <summary>Screen 9S: the operator types the addresses.</summary>
    Static,

    /// <summary>
    /// A machine deliberately kept off the network.
    ///
    /// AN EXPLICIT CHOICE, NOT THE ABSENCE OF ONE. Before Phase 3b every install
    /// produced this state and none of them chose it, which is L23 — an empty
    /// `/etc/netplan` reads identically whether somebody meant it or nobody was
    /// asked. Naming it makes the plan file able to tell the two apart.
    /// </summary>
    None,
}

internal enum LinkKind { Wired, Wireless }

internal enum WifiSecurity
{
    /// <summary>WPA2/WPA3 with a passphrase. netplan `key-management: psk`.</summary>
    Psk,

    /// <summary>WPA2/WPA3 Enterprise. netplan `key-management: eap`, `method: peap`.</summary>
    Enterprise,
}

/// <summary>
/// The network half of the plan — SETUP-PLAN §7.2, screens 9, 9S and 9W.
///
/// It exists because of L23, which was measured rather than assumed: the shipped
/// image has an empty `/etc/netplan`, an empty `/etc/systemd/network`, no
/// `cloud-init` and no enabled `systemd-networkd`. Nothing configures a network
/// on an installed OS/7 machine except NetworkManager, which only the amd64
/// desktop has. Until this screen existed, every headless install produced a
/// machine that had to be visited to be reached.
///
/// The renderer is NOT stored here, and that is deliberate (D14/L24). It is a
/// function of `InstallPlan.Mode` — screen 8's answer — and deriving it at write
/// time is what keeps it from depending on whether the desktop purge has already
/// run. A field here would be a second place for it to be wrong.
/// </summary>
internal sealed class NetworkPlan
{
    /// <summary>
    /// The interface, or `"auto"` for a netplan `match:` glob.
    ///
    /// L28: §6.6 makes the plan a file written on one machine and replayed on
    /// another, and `enp1s0` is a property of the machine that happened to be in
    /// front of the operator, not of the plan. An interactive install writes the
    /// name it was shown; an unattended plan may say `auto` and get `en*` or
    /// `wl*`. Same trap as `/dev/sdb` in `StoragePlan.Disk`, same fix.
    /// </summary>
    public string? Interface { get; set; }

    /// <summary>
    /// The chosen adapter's MAC, and WHAT NETPLAN ACTUALLY MATCHES ON.
    ///
    /// MEASURED 2026-08-25, and it is the reason this field exists. The same
    /// machine, the same NIC, the same MAC — and two different interface names:
    ///
    ///   installing, with the setup medium attached      enp0s5
    ///   booted from the disk, medium removed            enp0s2
    ///
    /// Predictable interface names are derived from the PCI topology, and the
    /// install medium is a PCI device. Removing it renumbers the slots. So the
    /// name Setup sees while installing is NOT the name the installed machine
    /// will use, and a netplan file naming `enp0s5` matches nothing after the
    /// reboot — which netplan accepts in silence. The result is the exact
    /// failure this whole phase exists to prevent: no address, no route, no
    /// error, and a machine nobody can reach.
    ///
    /// A MAC address does not move when a disk is unplugged. `Interface` is kept
    /// because it is what the operator saw on screen 9 and what the log and
    /// screen 12 should say; the netplan `match:` uses this.
    /// </summary>
    public string? MacAddress { get; set; }

    public LinkKind Kind { get; set; } = LinkKind.Wired;

    public NetworkMethod Method { get; set; } = NetworkMethod.Dhcp;

    /// <summary>With the prefix length — `10.42.0.17/24`, the way netplan wants
    /// it and the way a person reads it back off a screen.</summary>
    public string? Address { get; set; }

    /// <summary>Blank is legal: a segment with no route off it is a real thing,
    /// and refusing to install without a gateway would be Setup inventing a
    /// requirement the network does not have.</summary>
    public string? Gateway { get; set; }

    public List<string> Nameservers { get; set; } = new();

    public List<string> Search { get; set; } = new();

    /// <summary>Present exactly when <see cref="Kind"/> is Wireless.</summary>
    public WifiPlan? Wifi { get; set; }

    /// <summary>
    /// Whether the settings were applied and tested in the live environment
    /// before being written (D12).
    ///
    /// Recorded rather than required. An operator building a machine for a site
    /// that is not wired yet must be able to type a static address and continue;
    /// what must not happen is that a machine goes out with an untested config
    /// and nothing anywhere says so. Screen 12 repeats it, and the plan file
    /// carries it.
    /// </summary>
    public bool Verified { get; set; }

    /// <summary>What the test actually saw, for the log and for screen 12.</summary>
    public string? VerifiedDetail { get; set; }

    public void Validate(List<string> problems)
    {
        if (Method == NetworkMethod.None)
        {
            // Nothing else is required, and nothing else is checked. A screen —
            // or a plan — may only be refused for something it could have got
            // right, and "no address" is the point of this choice.
            return;
        }

        if (string.IsNullOrWhiteSpace(Interface))
            problems.Add("no network adapter was chosen");

        if (Method == NetworkMethod.Static)
        {
            if (string.IsNullOrWhiteSpace(Address))
                problems.Add("a static configuration needs an IP address");
            else if (!IsValidCidr(Address!))
                problems.Add($"'{Address}' is not an address with a prefix, like 10.42.0.17/24");

            if (!string.IsNullOrWhiteSpace(Gateway) && !IPAddress.TryParse(Gateway, out _))
                problems.Add($"'{Gateway}' is not a valid gateway address");

            foreach (string dns in Nameservers)
                if (!IPAddress.TryParse(dns, out _))
                    problems.Add($"'{dns}' is not a valid DNS server address");
        }

        if (Kind == LinkKind.Wireless)
        {
            if (Wifi is null) problems.Add("a wireless adapter was chosen but no network was");
            else Wifi.Validate(problems);
        }
        else if (Wifi is not null)
        {
            problems.Add("a wireless network was set on a wired adapter");
        }
    }

    /// <summary>
    /// An address with a prefix length, which is what netplan's `addresses:`
    /// takes and what the whole static path is written in.
    ///
    /// Checked HERE rather than left to netplan, because netplan fails on the
    /// TARGET — inside a chroot, several steps and some minutes after the screen
    /// that could have said so. The same reasoning as AccountPlan's username
    /// check and `useradd`.
    /// </summary>
    public static bool IsValidCidr(string s)
    {
        int slash = s.IndexOf('/');
        if (slash <= 0 || slash == s.Length - 1) return false;
        if (!IPAddress.TryParse(s[..slash], out IPAddress? ip)) return false;
        if (!int.TryParse(s[(slash + 1)..], out int bits)) return false;
        int max = ip.AddressFamily == AddressFamily.InterNetworkV6 ? 128 : 32;
        return bits >= 0 && bits <= max;
    }

    /// <summary>
    /// Split a comma- or space-separated field into entries, dropping blanks.
    ///
    /// Screens 9S offers ONE field for DNS servers rather than three, because
    /// three fields is three chances to leave one half-filled and the netplan
    /// key is a list either way.
    /// </summary>
    public static List<string> SplitList(string s) =>
        s.Split(new[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries
                                          | StringSplitOptions.TrimEntries)
         .ToList();

    // -----------------------------------------------------------------------
    // netplan
    // -----------------------------------------------------------------------

    /// <summary>
    /// The netplan document, as text.
    ///
    /// A PURE FUNCTION OF THE PLAN, and that is what makes it checkable without
    /// a target, a chroot or a VM: `--self-test` renders several plans and
    /// asserts what comes out, and hook 0080 runs `--self-test` inside the chroot
    /// during the ISO build. A generator that only runs against a real disk is a
    /// generator whose first test is an install.
    ///
    /// The renderer is a PARAMETER, never a field (D14). `NetworkStep` passes
    /// `InstallPlan.Mode`'s answer; nothing here may look at what is installed.
    /// </summary>
    public string ToNetplanYaml(string renderer, string version)
    {
        if (Method == NetworkMethod.None)
            throw new InvalidOperationException(
                "Method.None writes no netplan file; NetworkStep must not call this.");

        bool wireless = Kind == LinkKind.Wireless;

        // THE DEVICE ID IS A LABEL, NOT A NAME, whenever there is a `match:`
        // below it — netplan keys the block by this string and decides which
        // hardware it means from the match. Using `os7net` rather than the
        // interface name makes that unmistakable: an id that looks like an
        // interface name invites the next reader to believe the name is what
        // selects the device, which is exactly the mistake this file's
        // MacAddress comment documents.
        bool matching = !string.IsNullOrWhiteSpace(MacAddress) || Interface == "auto";
        string id = matching ? "os7net" : Interface!;

        var y = new StringBuilder();
        y.Append("# Written by OS/7 Setup ").Append(version).Append(".\n");
        y.Append("#\n");
        y.Append("# Regenerated by Setup on every install. Edit freely afterwards -\n");
        y.Append("# nothing in OS/7 rewrites this file after the machine is installed.\n");
        y.Append("network:\n");
        y.Append("  version: 2\n");
        y.Append("  renderer: ").Append(renderer).Append('\n');
        y.Append(wireless ? "  wifis:\n" : "  ethernets:\n");
        y.Append("    ").Append(id).Append(":\n");

        if (!string.IsNullOrWhiteSpace(MacAddress))
        {
            // L30. The MAC, because the NAME CHANGES between installing and
            // running — measured, see MacAddress. This is the normal path for an
            // interactive install: the operator picked a port, and this is the
            // only property of that port which survives the setup medium being
            // removed.
            y.Append("      match:\n");
            y.Append("        macaddress: \"").Append(MacAddress!.ToLowerInvariant())
             .Append("\"\n");
        }
        else if (Interface == "auto")
        {
            // L28. A glob, because the plan is replayed on a machine whose
            // interface names — and whose MACs — Setup has never seen.
            y.Append("      match:\n");
            y.Append("        name: \"").Append(wireless ? "wl*" : "en*").Append("\"\n");
        }

        if (Method == NetworkMethod.Dhcp)
        {
            y.Append("      dhcp4: true\n");
            // dhcp6 AND accept-ra: a network that offers DHCPv6 and one that
            // offers only router advertisements are both real, and asking for
            // one of them is how a machine ends up with no v6 on the other.
            y.Append("      dhcp6: true\n");
            y.Append("      accept-ra: true\n");
        }
        else
        {
            y.Append("      dhcp4: false\n");
            y.Append("      dhcp6: false\n");
            y.Append("      addresses:\n");
            y.Append("        - ").Append(Address).Append('\n');
            if (!string.IsNullOrWhiteSpace(Gateway))
            {
                // `routes: [{to: default, via: …}]`, NOT `gateway4:`. netplan
                // deprecated gateway4/gateway6 and warns on them; the warning
                // goes to a log nobody on a headless machine reads.
                y.Append("      routes:\n");
                y.Append("        - to: default\n");
                y.Append("          via: ").Append(Gateway).Append('\n');
            }
            if (Nameservers.Count > 0 || Search.Count > 0)
            {
                y.Append("      nameservers:\n");
                if (Nameservers.Count > 0)
                {
                    y.Append("        addresses:\n");
                    foreach (string dns in Nameservers)
                        y.Append("          - ").Append(dns).Append('\n');
                }
                if (Search.Count > 0)
                {
                    y.Append("        search:\n");
                    foreach (string d in Search)
                        y.Append("          - ").Append(Quote(d)).Append('\n');
                }
            }
        }

        if (wireless && Wifi is not null) Wifi.AppendTo(y);
        return y.ToString();
    }

    /// <summary>
    /// A YAML double-quoted scalar.
    ///
    /// Not decoration: an SSID may contain a colon, a `#`, a leading `-` or a
    /// space, and every one of those changes what the line means unquoted. A
    /// passphrase may contain a backslash. Only `\` and `"` need escaping inside
    /// a double-quoted scalar, and control characters cannot get here — TextBox
    /// refuses them and `Set` strips them, so the value is what somebody typed.
    /// </summary>
    public static string Quote(string s) =>
        "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
}

/// <summary>
/// Screen 9W — the wireless network and how to authenticate to it.
///
/// D13 puts both PSK and 802.1X in v1, and they are not equally proven: PSK is
/// measured against a real association, 802.1X is generated configuration and a
/// screen walk. See SETUP-PLAN Phase 3b for what that means and why the line is
/// where it is.
/// </summary>
internal sealed class WifiPlan
{
    public string Ssid { get; set; } = "";

    /// <summary>A network that does not broadcast. netplan `hidden: true`, which
    /// changes the scan technique rather than being cosmetic.</summary>
    public bool Hidden { get; set; }

    public WifiSecurity Security { get; set; } = WifiSecurity.Psk;

    /// <summary>
    /// NEVER SERIALISED. L25, and the third instance of this rule in this
    /// codebase after the LUKS passphrase and the account password — each of the
    /// first two was written as though it were the only one.
    ///
    /// It still reaches the target in plaintext inside the netplan file, because
    /// that is netplan's design and Ubuntu does the same. What this attribute
    /// stops is the secret entering the plan JSON, which goes into `--print-plan`
    /// output, a log, a screenshot and a repository. `--unattend` takes it from
    /// `--wifi-secret-file`.
    /// </summary>
    [JsonIgnore]
    public string? Psk { get; set; }

    public string? Identity { get; set; }

    /// <summary>The identity sent in the clear, outside the TLS tunnel. Optional,
    /// and blank means the real one is used — which is what most deployments
    /// do.</summary>
    public string? AnonymousIdentity { get; set; }

    /// <summary>NEVER SERIALISED, for the same reason as <see cref="Psk"/>.</summary>
    [JsonIgnore]
    public string? Password { get; set; }

    /// <summary>
    /// A path to a CA certificate, or blank.
    ///
    /// L27: there is no certificate store in 80×25 and no UI for importing,
    /// viewing or trusting one. Blank is legal and means the RADIUS server is not
    /// verified — which screen 9W PRINTS rather than defaulting to silently.
    /// </summary>
    public string? CaCertificate { get; set; }

    /// <summary>WPA2's minimum, and wpa_supplicant's. Checked here because the
    /// alternative is finding out at association time on a machine that is about
    /// to be installed headless.</summary>
    public const int MinimumPsk = 8;
    public const int MaximumPsk = 63;

    public void Validate(List<string> problems)
    {
        if (string.IsNullOrWhiteSpace(Ssid))
            problems.Add("no wireless network was chosen");
        else if (Ssid.Length > 32)
            problems.Add($"'{Ssid}' is too long for a network name (32 characters)");

        if (Security == WifiSecurity.Psk)
        {
            if (string.IsNullOrEmpty(Psk))
                problems.Add("the wireless network has no passphrase");
            else if (Psk!.Length is < MinimumPsk or > MaximumPsk)
                problems.Add($"a WPA passphrase is {MinimumPsk} to {MaximumPsk} characters");
        }
        else
        {
            if (string.IsNullOrWhiteSpace(Identity))
                problems.Add("802.1X needs an identity");
            if (string.IsNullOrEmpty(Password))
                problems.Add("802.1X needs a password");
        }
    }

    /// <summary>The `access-points:` block, indented to sit under the interface.</summary>
    public void AppendTo(StringBuilder y)
    {
        y.Append("      access-points:\n");
        y.Append("        ").Append(NetworkPlan.Quote(Ssid)).Append(":\n");
        if (Hidden) y.Append("          hidden: true\n");
        y.Append("          auth:\n");

        if (Security == WifiSecurity.Psk)
        {
            y.Append("            key-management: psk\n");
            y.Append("            password: ").Append(NetworkPlan.Quote(Psk ?? "")).Append('\n');
            return;
        }

        y.Append("            key-management: eap\n");
        y.Append("            method: peap\n");
        y.Append("            identity: ").Append(NetworkPlan.Quote(Identity ?? "")).Append('\n');
        if (!string.IsNullOrWhiteSpace(AnonymousIdentity))
            y.Append("            anonymous-identity: ")
             .Append(NetworkPlan.Quote(AnonymousIdentity!)).Append('\n');
        y.Append("            password: ").Append(NetworkPlan.Quote(Password ?? "")).Append('\n');
        y.Append("            phase2-auth: MSCHAPV2\n");
        if (!string.IsNullOrWhiteSpace(CaCertificate))
            y.Append("            ca-certificate: ")
             .Append(NetworkPlan.Quote(CaCertificate!)).Append('\n');
    }
}
