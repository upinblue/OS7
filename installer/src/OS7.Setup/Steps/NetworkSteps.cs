using OS7.Setup.Diagnostics;
using OS7.Setup.Model;

namespace OS7.Setup.Steps;

/// <summary>
/// Applying the network in the LIVE environment, so the operator finds out now.
///
/// D12: live is the verification, the target write is the deliverable. This is
/// the only moment at which a mistyped static address or a wrong Wi-Fi
/// passphrase can be caught by the person who typed it — after the reboot, a
/// headless machine with a wrong address is a site visit
/// (RELEASE-AND-UPDATE-PLAN §4.4).
///
/// IT RUNS THE SAME GENERATOR AS THE TARGET WRITE. `NetworkPlan.ToNetplanYaml`
/// produces the file for both, so what is tested here is the document that will
/// be installed, not a second implementation that agrees with it today.
/// </summary>
internal static class NetworkProbe
{
    /// <summary>Where the live test writes. /etc on the live medium is an
    /// overlay in RAM, so this never reaches a disk and never survives a
    /// reboot.</summary>
    private const string LiveFile = "/etc/netplan/99-os7-setup-test.yaml";

    /// <summary>
    /// The renderer the LIVE system can actually drive.
    ///
    /// THIS IS THE ONE PLACE IN SETUP WHERE "what is installed right now" IS THE
    /// CORRECT QUESTION, and it is correct because it is a question about the
    /// live medium rather than about the plan. The amd64 live image runs
    /// NetworkManager (it ships `10-globally-managed-devices.conf` and takes
    /// every device); arm64 has no NetworkManager at all. Handing netplan a
    /// renderer that is not there produces a config nothing reads and an
    /// interface that never comes up, with no error.
    ///
    /// The TARGET's renderer is a different question with a different answer —
    /// `InstallPlan.Renderer`, derived from screen 8 (D14). The two disagree on
    /// exactly one product: an amd64 headless install, where the live system has
    /// NM and the installed system will not.
    /// </summary>
    private static string LiveRenderer()
    {
        bool nm = File.Exists("/usr/sbin/NetworkManager") || File.Exists("/usr/bin/nmcli");
        return nm ? "NetworkManager" : "networkd";
    }

    /// <summary>
    /// Apply and check. Returns whether it worked and one line saying what was
    /// seen, which is what the screen prints.
    ///
    /// THE ANSWER COMES FROM `ip`, NOT FROM `netplan apply`'s EXIT CODE.
    /// `netplan apply` returns 0 for a configuration that is syntactically fine
    /// and brings nothing up — a wrong passphrase, an absent DHCP server, a
    /// cable in the wrong port all look identical to it. Asking the kernel what
    /// addresses the interface has is a diagnostic that does not depend on the
    /// subsystem it is diagnosing.
    /// </summary>
    public static (bool Ok, string Detail) Test(InstallPlan plan)
    {
        NetworkPlan n = plan.Network;
        if (n.Method == NetworkMethod.None)
            return (false, "There is nothing to test: this computer will have no network.");
        if (string.IsNullOrWhiteSpace(n.Interface))
            return (false, "No network adapter was chosen.");

        string iface = n.Interface!;
        try
        {
            string yaml = n.ToNetplanYaml(LiveRenderer(), Release.Current.Version);
            Directory.CreateDirectory("/etc/netplan");
            File.WriteAllText(LiveFile, yaml.ReplaceLineEndings("\n"));
            // 0600 before anything else can read it: for a wireless network this
            // file holds the passphrase in plaintext (L25), and netplan itself
            // warns about world-readable configuration for the same reason.
            WifiScan.Run("chmod", "0600", LiveFile);

            if (n.Kind == LinkKind.Wireless)
            {
                WifiScan.Run("rfkill", "unblock", "wifi");
                WifiScan.Run("ip", "link", "set", iface, "up");
            }

            Log.Info($"live test: applying {LiveFile} for {iface}");
            string? applied = WifiScan.Run("netplan", "apply");
            if (applied is null)
                return (false, "netplan could not apply the configuration - see the log.");

            return Await(n, iface);
        }
        catch (Exception ex)
        {
            Log.Error($"live test failed: {ex.Message}");
            return (false, $"The test could not run: {ex.Message}");
        }
        finally
        {
            // The test file must not be left where a later `netplan apply` on
            // this medium would pick it up again with a stale passphrase in it.
            try { if (File.Exists(LiveFile)) File.Delete(LiveFile); } catch { }
        }
    }

    /// <summary>
    /// Wait for the interface to have what was asked for.
    ///
    /// A LEASE TAKES SECONDS AND AN ASSOCIATION TAKES LONGER, so the check is a
    /// poll rather than a single look — the first version of this asked once,
    /// immediately after `netplan apply`, and reported failure on every network
    /// that worked. Thirty seconds covers a slow DHCP server and a 5 GHz
    /// association; beyond that the honest answer is that it did not work.
    /// </summary>
    private static (bool Ok, string Detail) Await(NetworkPlan n, string iface)
    {
        string want = n.Method == NetworkMethod.Static ? n.Address ?? "" : "";
        DateTime deadline = DateTime.UtcNow.AddSeconds(30);
        string last = "";

        while (DateTime.UtcNow < deadline)
        {
            string? shown = WifiScan.Run("ip", "-o", "addr", "show", "dev", iface);
            if (shown is not null)
            {
                last = shown;
                if (want.Length > 0)
                {
                    if (shown.Contains(want, StringComparison.Ordinal))
                    {
                        n.Verified = true;
                        n.VerifiedDetail = $"{iface} has {want}";
                        Log.Info($"live test OK: {n.VerifiedDetail}");
                        return (true, $"{iface} has {want}. The settings work.");
                    }
                }
                else
                {
                    // DHCP: any global address counts, and the address itself is
                    // what goes on the screen - "connected" is a word, an address
                    // is a measurement.
                    string? addr = FirstGlobal(shown);
                    if (addr is not null)
                    {
                        n.Verified = true;
                        n.VerifiedDetail = $"{iface} was given {addr}";
                        Log.Info($"live test OK: {n.VerifiedDetail}");
                        return (true, $"{iface} was given {addr}. The settings work.");
                    }
                }
            }
            Thread.Sleep(1000);
        }

        n.Verified = false;
        n.VerifiedDetail = null;
        Log.Warn($"live test: {iface} did not come up. Last: {last.Trim()}");
        return (false, n.Kind == LinkKind.Wireless
            ? $"{iface} did not join the network. Check the passphrase."
            : $"{iface} got no address in 30 seconds.");
    }

    /// <summary>
    /// The first globally-scoped address out of `ip -o addr show`.
    ///
    /// SCOPE MATTERS. An interface with no lease still has a link-local
    /// `fe80::/64` and, if the DHCP server never answered, may have a
    /// `169.254.0.0/16` autoconfiguration address. Both are addresses and
    /// neither means the network works, so counting them would make this check
    /// pass on precisely the failure it exists to catch.
    /// </summary>
    internal static string? FirstGlobal(string ipOutput)
    {
        foreach (string line in ipOutput.Split('\n'))
        {
            if (!line.Contains("scope global", StringComparison.Ordinal)) continue;
            string[] parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            for (int i = 0; i < parts.Length - 1; i++)
            {
                if (parts[i] is not ("inet" or "inet6")) continue;
                string candidate = parts[i + 1];
                if (candidate.StartsWith("169.254.", StringComparison.Ordinal)) continue;
                return candidate;
            }
        }
        return null;
    }
}

// ---------------------------------------------------------------------------

/// <summary>
/// Write the network onto the TARGET — SETUP-PLAN Phase 3b, L23, L24, D14.
///
/// THE ROOT IS A PARAMETER, like every other chroot step: `Update-OS7` runs this
/// same sequence against a cloned boot environment mounted somewhere else
/// (RELEASE-AND-UPDATE-PLAN §4.2).
///
/// IT RUNS AFTER `InstallModeStep`, AND THAT IS THE POINT (L24). The headless
/// path purges the desktop and then runs `apt-get autoremove -y --purge`, which
/// takes `network-manager` with it. A NetworkManager-rendered netplan written
/// before that purge names a backend that is no longer installed — a machine
/// with no network and no error at install time. The renderer is read from the
/// plan rather than probed for the same reason: probing gives a different answer
/// depending on whether the purge has run.
/// </summary>
internal sealed class NetworkStep : IStep
{
    private readonly InstallPlan _plan;
    private readonly TargetRoot _t;

    /// <summary>Numbered `01-` so it sorts before anything a person adds later,
    /// and named so that what wrote it is obvious from `ls`.</summary>
    public const string File = "etc/netplan/01-os7-network.yaml";

    public NetworkStep(InstallPlan plan, TargetRoot t) { _plan = plan; _t = t; }

    public string Describe => _plan.Network.Method == NetworkMethod.None
        ? "Leaving the network unconfigured"
        : "Configuring the network";

    public void Run(Executor x)
    {
        NetworkPlan n = _plan.Network;

        if (n.Method == NetworkMethod.None)
        {
            // An explicit choice (L23), so it is logged as one. Nothing is
            // written and nothing is enabled - and the machine that comes out is
            // the machine every install produced before this step existed, with
            // the difference that somebody chose it.
            Log.Info("network: none was chosen; nothing written to /etc/netplan");
            return;
        }

        string renderer = _plan.Renderer;
        string yaml = n.ToNetplanYaml(renderer, Release.Current.Version);

        // 0600: the file holds the Wi-Fi passphrase or the 802.1X password in
        // plaintext (L25). netplan itself refuses to be quiet about a
        // world-readable configuration, and it is right to.
        _t.Write(x, File, yaml, "0600");

        Log.Info($"network: renderer {renderer} (mode {_plan.Mode}), "
                 + $"{n.Method} on {n.Interface}");

        if (renderer == "networkd") EnableNetworkd(x);
        Generate(x, renderer, n);
    }

    /// <summary>
    /// Turn `systemd-networkd` on, because NOTHING ELSE DOES.
    ///
    /// This is the concrete shape of L23 and the easiest half of it to forget.
    /// Measured on both shipped images 2026-08-25: `systemd-networkd` is not
    /// enabled, and what IS enabled is `networkd-dispatcher.service` — which
    /// exists to REACT to networkd's state changes. The consumer is switched on
    /// and the producer is not, so the enabled-units list reads like evidence
    /// that networking is configured.
    ///
    /// WHETHER NETPLAN WOULD HAVE DONE THIS ANYWAY IS NOT KNOWN HERE, and the
    /// honest version matters more than the tidy one. `netplan-generator` runs
    /// as a systemd generator at boot and may enable `systemd-networkd` itself
    /// once `/etc/netplan` has content — that has not been measured, and this
    /// comment is not going to claim it either way. What HAS been measured is
    /// that the shipped image does not enable it, so on a machine installed
    /// before Phase 3b nothing did. Enabling it explicitly costs one `systemctl`
    /// and removes the question; `run-phase3b-network.py boot` then asks the
    /// booted machine `systemctl is-active systemd-networkd`, which is the
    /// answer that counts.
    ///
    /// `/etc/resolv.conf` goes with it: `systemd-resolved` serves a stub at
    /// `/run/systemd/resolve/stub-resolv.conf`, and a machine whose resolv.conf
    /// does not point at it resolves nothing while looking perfectly configured.
    /// </summary>
    private void EnableNetworkd(Executor x)
    {
        _t.Chroot(x, "networkd", """
            echo ">>> enabling systemd-networkd and systemd-resolved"
            systemctl enable systemd-networkd.service systemd-resolved.service

            # Proof from the SYMLINKS, not from systemctl's exit code: `enable`
            # on a masked or absent unit reports its own opinion, and what
            # decides at boot is whether the want exists on disk.
            for U in systemd-networkd systemd-resolved; do
                if [ -e "/etc/systemd/system/multi-user.target.wants/$U.service" ] ||
                   [ -e "/etc/systemd/system/dbus-org.freedesktop.network1.service" ] ||
                   [ -e "/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" ] ||
                   systemctl is-enabled "$U" >/dev/null 2>&1; then
                    echo "    $U is enabled"
                else
                    echo "!!! $U is NOT enabled after systemctl enable" >&2
                    exit 1
                fi
            done

            echo ">>> pointing /etc/resolv.conf at the resolved stub"
            ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            readlink /etc/resolv.conf
            """);
    }

    /// <summary>
    /// Ask netplan to turn the YAML into backend configuration, and READ BACK
    /// WHAT IT PRODUCED.
    ///
    /// `netplan apply` cannot run here: it needs a live systemd, which a chroot
    /// has not — the same reason this file's neighbours avoid `systemctl start`.
    /// `netplan generate` can, and it writes
    /// `/run/systemd/network/10-netplan-<id>.network` for the networkd renderer
    /// and `/run/NetworkManager/system-connections/netplan-<id>*.nmconnection`
    /// for the other one.
    ///
    /// THE CHECK IS THE GENERATED FILE, NEVER THE EXIT CODE. `netplan generate`
    /// exits 0 on a document that produces nothing at all — a `match:` that
    /// matches no interface, a renderer whose backend is absent. Reading the
    /// unit back and looking for `DHCP=` or the typed `Address=` is a diagnostic
    /// that needs no running networkd, no link and no DHCP server. It is the
    /// same rule that made `AccountStep` read `/etc/shadow` rather than trust
    /// `useradd`.
    /// </summary>
    private void Generate(Executor x, string renderer, NetworkPlan n)
    {
        // What must appear in the generated networkd unit. For DHCP netplan
        // writes `DHCP=ipv4` or `DHCP=yes` depending on version, so the check is
        // on the key rather than on one spelling of the value.
        string needle = n.Method == NetworkMethod.Static ? n.Address! : "DHCP=";

        // `|| true` ON EVERY `ls`, AND IT IS NOT DECORATION. TargetRoot.Chroot
        // wraps this in `set -euo pipefail`. `ls` on a glob that matches nothing
        // exits non-zero, and with `pipefail` the pipeline inherits it — so the
        // assignment fails, `set -e` kills the script, and the carefully worded
        // message two lines below NEVER PRINTS. The failure would arrive as a
        // bare non-zero exit from a step called "netplan", which says nothing at
        // all about what was wrong. `bash -n` cannot see this: the syntax is
        // fine and the semantics are not.
        string check = renderer == "networkd"
            ? $"""
               OUT=$(ls /run/systemd/network/*.network 2>/dev/null | head -20 || true)
               if [ -z "$OUT" ]; then
                   echo "!!! netplan generate produced no networkd unit" >&2
                   echo "    the netplan file is /etc/netplan/01-os7-network.yaml" >&2
                   exit 1
               fi
               echo "    generated:"; echo "$OUT" | sed 's/^/      /'
               if grep -qF '{needle}' /run/systemd/network/*.network; then
                   echo "    the generated unit carries {needle}"
               else
                   echo "!!! no generated unit carries {needle}" >&2
                   cat /run/systemd/network/*.network >&2 || true
                   exit 1
               fi
               """
            : """
              OUT=$(ls /run/NetworkManager/system-connections/ 2>/dev/null || true)
              if [ -z "$OUT" ]; then
                  echo "!!! netplan generate produced no NetworkManager connection" >&2
                  echo "    the netplan file is /etc/netplan/01-os7-network.yaml" >&2
                  exit 1
              fi
              echo "    generated:"; echo "$OUT" | sed 's/^/      /'
              """;

        _t.Chroot(x, "netplan", $"""
            echo ">>> netplan generate"
            netplan generate
            {check}
            """);
    }
}
