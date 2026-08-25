using System.Diagnostics;
using OS7.Setup.Diagnostics;

namespace OS7.Setup.Model;

/// <summary>
/// One network adapter, as `/sys/class/net` describes it.
///
/// `Carrier` is the interesting field. A plugged-in cable is the operator
/// telling Setup which port they mean, and it costs one file read to notice —
/// so screen 9 pre-selects the first wired adapter that has one. On a machine
/// with four NICs and one cable that is the difference between a choice and a
/// guess.
/// </summary>
internal sealed record NetworkLink(
    string Name,
    LinkKind Kind,
    bool Carrier,
    string OperState,
    string Mac,
    string Driver)
{
    /// <summary>The row screen 9 draws, in columns that line up.</summary>
    public string Row(int width)
    {
        string kind = Kind == LinkKind.Wireless ? "Wi-Fi" : "Ethernet";
        string state = Kind == LinkKind.Wireless
            ? (OperState == "up" ? "up" : "")
            : (Carrier ? "link up" : "no link");
        string row = $"{Name,-12} {kind,-10} {Driver,-16} {state}";
        return row.Length > width ? row[..width] : row;
    }
}

internal static class NetworkLinks
{
    private const string SysNet = "/sys/class/net";

    /// <summary>
    /// Every adapter Setup may offer, in a stable order.
    ///
    /// WHAT IS LEFT OUT AND WHY:
    ///
    ///   `lo`          - not an adapter anybody configures.
    ///   no `device/`  - bridges, veth, docker0, bonds and tunnels are virtual
    ///                   interfaces with no hardware behind them. On the live
    ///                   medium these do not exist yet; the check is here so that
    ///                   a machine Setup is re-run on does not offer them.
    ///
    /// Sorted wired-with-carrier first, then wired, then wireless, then by name,
    /// so the row the operator most likely wants is the row the cursor starts on
    /// and the order does not change between runs.
    /// </summary>
    public static List<NetworkLink> Enumerate()
    {
        var found = new List<NetworkLink>();
        try
        {
            if (!Directory.Exists(SysNet))
            {
                Log.Warn($"{SysNet} does not exist; no network adapters can be offered");
                return found;
            }

            foreach (string dir in Directory.GetDirectories(SysNet))
            {
                string name = Path.GetFileName(dir);
                if (name == "lo") continue;
                if (!Directory.Exists(Path.Combine(dir, "device"))) continue;

                bool wireless = Directory.Exists(Path.Combine(dir, "wireless"))
                                || Directory.Exists(Path.Combine(dir, "phy80211"));

                found.Add(new NetworkLink(
                    name,
                    wireless ? LinkKind.Wireless : LinkKind.Wired,
                    // carrier reads EINVAL on a down interface, which File.Read
                    // surfaces as an exception. "no link" is the right answer
                    // there, not a crash.
                    Carrier: Read(dir, "carrier") == "1",
                    OperState: Read(dir, "operstate") ?? "unknown",
                    Mac: Read(dir, "address") ?? "",
                    Driver: DriverOf(dir)));
            }
        }
        catch (Exception ex)
        {
            Log.Error($"could not read {SysNet}: {ex.Message}");
        }

        found.Sort((a, b) =>
        {
            int rank(NetworkLink l) =>
                l.Kind == LinkKind.Wired ? (l.Carrier ? 0 : 1) : 2;
            int r = rank(a).CompareTo(rank(b));
            return r != 0 ? r : string.CompareOrdinal(a.Name, b.Name);
        });

        Log.Info($"network adapters: {found.Count} "
                 + string.Join(", ", found.Select(l => $"{l.Name}({l.Kind},{l.Driver})")));
        return found;
    }

    private static string? Read(string dir, string file)
    {
        try
        {
            string path = Path.Combine(dir, file);
            return File.Exists(path) ? File.ReadAllText(path).Trim() : null;
        }
        catch
        {
            // carrier on a down interface, and every other sysfs attribute that
            // answers with an errno rather than a value. Absent is the truth.
            return null;
        }
    }

    /// <summary>
    /// The kernel module driving the adapter — `virtio_net`, `e1000e`, `iwlwifi`.
    ///
    /// The MODEL would be nicer and is not available: naming "Intel I219-V" needs
    /// a PCI ID database, which is `pciutils`' `/usr/share/misc/pci.ids` and is
    /// not on the image. The driver name is on every machine, needs nothing, and
    /// is enough to tell two adapters apart — which is what the column is for.
    /// </summary>
    private static string DriverOf(string dir)
    {
        try
        {
            string link = Path.Combine(dir, "device", "driver");
            if (!Directory.Exists(link)) return "";
            string? target = Directory.ResolveLinkTarget(link, true)?.Name;
            return target ?? "";
        }
        catch { return ""; }
    }
}

/// <summary>One access point, as `iw scan` reported it.</summary>
internal sealed record WifiNetwork(string Ssid, int SignalDbm, WifiSecurity? Security)
{
    /// <summary>
    /// Four blocks of signal, drawn from the Block Elements range S1 proved is
    /// complete in the console font (L19).
    ///
    /// The thresholds are the conventional ones: -50 excellent, -60 good, -70
    /// usable, below that marginal.
    /// </summary>
    public string Bars => SignalDbm switch
    {
        >= -50 => "▂▄▆█",
        >= -60 => "▂▄▆",
        >= -70 => "▂▄",
        _ => "▂",
    };

    public string Label => Security switch
    {
        WifiSecurity.Enterprise => "WPA2 Enterprise (802.1X)",
        WifiSecurity.Psk => "WPA2/WPA3 Personal",
        _ => "open - no encryption",
    };

    public string Row(int width)
    {
        string row = $"{Ssid,-21}{Bars,-4}   {Label}";
        return row.Length > width ? row[..width] : row;
    }
}

internal static class WifiScan
{
    /// <summary>
    /// Scan, through `iw`.
    ///
    /// THE INTERFACE MUST BE UP FIRST. `iw dev X scan` on a down interface fails
    /// with "Network is down", which is an error about the command rather than
    /// about the radio, and it is the first thing anybody hits. `ip link set up`
    /// is therefore part of scanning and not a precondition somebody else has to
    /// remember.
    ///
    /// Returns an empty list and logs on every failure rather than throwing:
    /// screen 9W has to be able to draw "no networks found" and offer a rescan,
    /// and a wireless adapter with a hardware kill switch is a normal thing to
    /// find, not an install-stopping error.
    /// </summary>
    public static List<WifiNetwork> Scan(string iface)
    {
        Run("rfkill", "unblock", "wifi");
        Run("ip", "link", "set", iface, "up");

        string? output = Run("iw", "dev", iface, "scan");
        if (output is null)
        {
            Log.Warn($"scan on {iface} produced nothing");
            return new List<WifiNetwork>();
        }
        return Parse(output);
    }

    /// <summary>
    /// Parse `iw scan` output.
    ///
    /// SEPARATE FROM THE COMMAND ON PURPOSE, so `--self-test` can feed it a
    /// captured scan and assert what comes out. A parser whose only test is a
    /// wireless card is a parser that is tested on one network, once.
    ///
    /// The shape it reads:
    ///
    ///     BSS aa:bb:cc:dd:ee:ff(on wlan0)
    ///             signal: -45.00 dBm
    ///             SSID: CORP-GUEST
    ///             RSN:     * Version: 1
    ///                      * Authentication suites: PSK
    ///
    /// Strongest signal wins where a network appears on several BSSIDs, which is
    /// every real deployment with more than one access point.
    /// </summary>
    public static List<WifiNetwork> Parse(string output)
    {
        var best = new Dictionary<string, WifiNetwork>(StringComparer.Ordinal);
        string ssid = "";
        int signal = -100;
        WifiSecurity? security = null;
        bool haveBss = false;

        void Flush()
        {
            if (!haveBss || ssid.Length == 0) return;

            // A hidden network advertises a zero-length or zero-filled SSID. It
            // is real and it is not selectable from a list, which is why 9W has
            // an "enter a hidden network name" row instead of showing these.
            //
            // AND `iw` ESCAPES IT RATHER THAN EMITTING IT. A zero-filled SSID
            // arrives as the eight-character-per-byte text `\x00\x00…`, not as
            // NUL bytes — so a check for `c == '\0'` alone passes every hidden
            // network straight through into the list as a row of gibberish
            // nobody can select. Found by feeding this parser a captured scan in
            // `--self-test` rather than by looking at a radio.
            if (ssid.All(c => c == '\0')) return;
            if (ssid.Replace("\\x00", "").Length == 0) return;
            if (!best.TryGetValue(ssid, out WifiNetwork? had) || had.SignalDbm < signal)
                best[ssid] = new WifiNetwork(ssid, signal, security);
        }

        foreach (string raw in output.Split('\n'))
        {
            string line = raw.Trim();
            if (line.StartsWith("BSS ", StringComparison.Ordinal))
            {
                Flush();
                ssid = ""; signal = -100; security = null; haveBss = true;
                continue;
            }
            if (line.StartsWith("SSID: ", StringComparison.Ordinal))
            {
                ssid = line[6..];
            }
            else if (line.StartsWith("signal: ", StringComparison.Ordinal))
            {
                string n = line[8..].Replace("dBm", "").Trim();
                if (double.TryParse(n, System.Globalization.NumberStyles.Float,
                                    System.Globalization.CultureInfo.InvariantCulture,
                                    out double dbm))
                    signal = (int)Math.Round(dbm);
            }
            else if (line.Contains("Authentication suites:", StringComparison.Ordinal))
            {
                // 802.1X BEFORE PSK: an enterprise network's suite line reads
                // "IEEE 802.1X", and a network offering both is one Setup must
                // treat as enterprise or the association will fail with a
                // passphrase it was never going to accept.
                if (line.Contains("802.1X", StringComparison.Ordinal))
                    security = WifiSecurity.Enterprise;
                else if (line.Contains("PSK", StringComparison.Ordinal)
                         || line.Contains("SAE", StringComparison.Ordinal))
                    security = WifiSecurity.Psk;
            }
        }
        Flush();

        List<WifiNetwork> list = best.Values.ToList();
        list.Sort((a, b) => b.SignalDbm.CompareTo(a.SignalDbm));
        Log.Info($"scan found {list.Count} network(s)");
        return list;
    }

    /// <summary>
    /// Run something and return its stdout, or null.
    ///
    /// Not `Executor.Exec`: this runs from a SCREEN, before the executor exists,
    /// and nothing here writes to a disk. `Executor` carries rollback state for
    /// an install in progress, and borrowing it to scan for access points would
    /// put a scan in the undo log.
    /// </summary>
    internal static string? Run(string exe, params string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (string a in args) psi.ArgumentList.Add(a);

            using Process? p = Process.Start(psi);
            if (p is null) { Log.Warn($"{exe} did not start"); return null; }
            string @out = p.StandardOutput.ReadToEnd();
            string err = p.StandardError.ReadToEnd();
            p.WaitForExit();
            if (p.ExitCode != 0)
            {
                Log.Warn($"{exe} {string.Join(' ', args)} exited {p.ExitCode}: {err.Trim()}");
                return null;
            }
            return @out;
        }
        catch (Exception ex)
        {
            Log.Warn($"{exe} failed: {ex.Message}");
            return null;
        }
    }
}
