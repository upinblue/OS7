using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Steps;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 9S — the static TCP/IP settings. SETUP-PLAN §3.
///
/// Reached only from screen 9's "Specify an address", which is why it is
/// lettered rather than numbered: it is not a step in a line every install
/// walks, so it does not earn a number in one. Renumbering the screen list is
/// how BUILD-NOTES #45 happened.
///
/// A FORM, so TAB moves and ENTER commits — the same object as screen 7 and
/// drawn the same way. Four fields rather than six: the DNS servers share one
/// field because three fields is three chances to leave one half-filled and the
/// netplan key is a list either way.
/// </summary>
internal sealed class StaticScreen : Screen
{
    private readonly InstallPlan _plan;
    private string? _note;
    private bool _noteIsGood;

    private enum Field { Address, Gateway, Dns, Search }
    private Field _field = Field.Address;

    private readonly TextBox _address = new() { MaxLength = 43 };
    private readonly TextBox _gateway = new() { MaxLength = 39 };
    private readonly TextBox _dns = new() { MaxLength = 120 };
    private readonly TextBox _search = new() { MaxLength = 120 };

    public StaticScreen(InstallPlan plan)
    {
        _plan = plan;
        // Pre-filled, so ESC back into this screen shows what was typed and an
        // --unattend plan replayed interactively is editable.
        _address.Set(plan.Network.Address ?? "");
        _gateway.Set(plan.Network.Gateway ?? "");
        _dns.Set(string.Join(", ", plan.Network.Nameservers));
        _search.Set(string.Join(", ", plan.Network.Search));
    }

    public override string Status =>
        "TAB=Next field   F4=Test   ENTER=Continue   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        string iface = _plan.Network.Interface ?? "this computer";
        f.Body(3, 5, $"Setup needs the addresses this computer will use on {iface}.");

        int left = f.Left + 5;
        int width = f.BoxWidth;
        int fieldWidth = Math.Min(44, width - 22);

        f.Box(5, left, width, 10);
        Row(f, 6, left, fieldWidth, "IP address:", _address, Field.Address);
        Row(f, 8, left, fieldWidth, "Default gateway:", _gateway, Field.Gateway);
        Row(f, 10, left, fieldWidth, "DNS servers:", _dns, Field.Dns);
        Row(f, 12, left, fieldWidth, "Search domains:", _search, Field.Search);

        f.Body(16, 5, "The address is written with its prefix length, as 10.42.0.17/24.");
        f.Body(17, 5, "Leave the gateway blank for a segment with no route off it.");
        f.Body(18, 5, "Separate several DNS servers with commas.");

        if (_note is not null)
            f.Body(20, 5, _note, _noteIsGood ? Slot.White : Slot.Brand);
        else if (_plan.Network.Verified)
            f.Body(20, 5, $"Tested: {_plan.Network.VerifiedDetail}");
        else
            f.Body(20, 5, "Not yet tested.", Slot.Brand);
    }

    private void Row(Frame f, int row, int left, int width, string label,
                     TextBox box, Field which)
    {
        f.Text(row, left + 3, label);
        box.Draw(f, row, left + 21, width, _field == which);
    }

    public override Transition Handle(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Tab:
                _field = (Field)(((int)_field + 1) % 4);
                return Transition.Redraw;

            case Key.Up:
                _field = (Field)(((int)_field + 3) % 4);
                return Transition.Redraw;

            case Key.Down:
                _field = (Field)(((int)_field + 1) % 4);
                return Transition.Redraw;

            case Key.Escape:
                return Transition.Back;

            case Key.Enter:
                if (!Collect()) return Transition.Redraw;
                // 9D next, through its own Entry — one door, so that the
                // question "is there a domain to join here" is answered in one
                // place rather than by each screen that could reach it.
                return Transition.To(DomainScreen.Entry(_plan));

            // F4 and not `T`: every field here can legitimately contain a `t` —
            // `test.corp.example.com` is a search domain — so a letter would
            // mean two things depending on where the cursor was.
            case Key.F4:
                if (!Collect()) return Transition.Redraw;
                (bool ok, string detail) = NetworkProbe.Test(_plan);
                _note = detail;
                _noteIsGood = ok;
                return Transition.Redraw;

            default:
                var box = _field switch
                {
                    Field.Address => _address,
                    Field.Gateway => _gateway,
                    Field.Dns => _dns,
                    _ => _search,
                };
                if (!box.Handle(key)) return Transition.Stay;
                _note = null;
                return Transition.Redraw;
        }
    }

    /// <summary>
    /// What this screen collected, checked HERE and nowhere else.
    ///
    /// The whole-plan check runs at ExecuteScreen.Start. This one refuses only
    /// the four fields on this screen, because a screen may only be refused for
    /// something it could have got right (BUILD-NOTES #45). It also cannot be
    /// skipped: an unparseable address reaches netplan inside the chroot, six
    /// steps and several minutes after the screen that could have said so.
    /// </summary>
    private bool Collect()
    {
        var problems = new List<string>();

        string addr = _address.Value.Trim();
        if (addr.Length == 0)
            problems.Add("an IP address is needed");
        else if (!NetworkPlan.IsValidCidr(addr))
            problems.Add($"'{addr}' is not an address with a prefix, like 10.42.0.17/24");

        string gw = _gateway.Value.Trim();
        if (gw.Length > 0 && !System.Net.IPAddress.TryParse(gw, out _))
            problems.Add($"'{gw}' is not a valid gateway address");

        List<string> dns = NetworkPlan.SplitList(_dns.Value);
        foreach (string d in dns)
            if (!System.Net.IPAddress.TryParse(d, out _))
                problems.Add($"'{d}' is not a valid DNS server address");

        if (problems.Count > 0)
        {
            _note = problems[0];
            _noteIsGood = false;
            return false;
        }

        NetworkPlan n = _plan.Network;
        n.Address = addr;
        n.Gateway = gw.Length > 0 ? gw : null;
        n.Nameservers = dns;
        n.Search = NetworkPlan.SplitList(_search.Value);
        Log.Info($"network: static {n.Address} gw={n.Gateway ?? "-"} "
                 + $"dns=[{string.Join(' ', n.Nameservers)}]");
        return true;
    }
}
