using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Steps;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 9W — the wireless network and how to authenticate to it. SETUP-PLAN §3.
///
/// Reached only when the adapter chosen on screen 9 is wireless, and lettered
/// for the same reason 9S is: it is not a step every install walks.
///
/// TWO KINDS OF NETWORK, AND THEY ARE NOT EQUALLY PROVEN (D13). WPA2/WPA3-PSK is
/// measured against a real association in a VM; 802.1X (PEAP/MSCHAPv2) is
/// generated configuration and a screen walk, because testing it needs a RADIUS
/// server and the image carries none. SETUP-PLAN Phase 3b says so in the same
/// words, and this screen does not pretend otherwise.
///
/// AND NEITHER OF THEM IS EVIDENCE ABOUT A REAL RADIO. The harness tests against
/// `mac80211_hwsim`, which is a kernel module that simulates the hardware layer
/// away and loads no firmware at all. What is measured is this screen's scan,
/// association and netplan path; what is NOT measured is whether any actual
/// wireless chip in this image comes up. The 19 `linux-firmware` packages are on
/// both images (§7.2) and not one of them has been exercised.
///
/// L27 IS ON THE SCREEN, NOT IN A NOTE. There is no certificate store in 80×25,
/// so leaving the CA field blank means the RADIUS server is not verified — and
/// that is printed where the operator is looking rather than defaulted silently.
/// </summary>
internal sealed class WifiScreen : Screen
{
    private readonly InstallPlan _plan;
    private List<WifiNetwork> _found = new();
    private SelectionList _list;
    private string? _note;
    private bool _noteIsGood;
    private bool _scanned;

    private enum Field { List, Ssid, Identity, Secret, CaCert }
    private Field _field = Field.List;

    private readonly TextBox _ssid = new() { MaxLength = 32 };
    private readonly TextBox _identity = new() { MaxLength = 64 };
    private readonly TextBox _secret = new() { Masked = true, MaxLength = 63 };
    private readonly TextBox _cacert = new() { MaxLength = 96 };

    /// <summary>The extra row under the scan results. Index into the list.</summary>
    private int HiddenRow => _found.Count;

    public WifiScreen(InstallPlan plan)
    {
        _plan = plan;
        WifiPlan w = plan.Network.Wifi ??= new WifiPlan();
        _ssid.Set(w.Ssid);
        _identity.Set(w.Identity ?? "");
        _cacert.Set(w.CaCertificate ?? "");
        _list = Build();
    }

    /// <summary>
    /// The scan runs ON THE FIRST IDLE TICK, not in the constructor and not in
    /// Layout.
    ///
    /// `iw scan` takes seconds. SetupFlow's order is Layout → Draw → Show →
    /// Read, so a scan in either the constructor or Layout happens BEFORE
    /// anything reaches the console: the operator sees the previous screen, for
    /// several seconds, with nothing to say why. The first version did exactly
    /// that while carrying a comment claiming the opposite.
    ///
    /// Ticking instead costs one frame and gets the order right — "Setup is
    /// scanning…" is drawn and shown first, then the idle tick 200 ms later does
    /// the work. `Ticks` goes false afterwards so the screen stops being woken
    /// for nothing.
    /// </summary>
    public override bool Ticks => !_scanned;

    private SelectionList Build()
    {
        int width = SelectionList.TextWidth(Frame.BoxWidthFor(80));
        var rows = _found.Select(n => n.Row(width)).ToList();
        rows.Add("(enter a hidden network name)");

        int at = 0;
        string want = _plan.Network.Wifi?.Ssid ?? "";
        if (want.Length > 0)
        {
            int found = _found.FindIndex(n => n.Ssid == want);
            at = found >= 0 ? found : HiddenRow;
        }
        return new SelectionList(rows, visibleRows: 4, selected: at);
    }

    private void Rescan()
    {
        string iface = _plan.Network.Interface ?? "";
        if (iface.Length == 0)
        {
            _note = "No wireless adapter was chosen.";
            _noteIsGood = false;
            return;
        }
        _found = WifiScan.Scan(iface);
        _list = Build();
        _note = _found.Count > 0
            ? null
            : "No networks found. Press F6 to scan again, or enter a hidden name.";
        _noteIsGood = false;
    }

    private bool OnHidden => _list.Selected >= HiddenRow;

    /// <summary>
    /// What kind of network the fields are for.
    ///
    /// From the SCAN where there is one, because the access point already said
    /// so and asking the operator to repeat it is a chance to disagree with the
    /// radio. For a hidden network there is nothing to read it off, so the
    /// screen falls back to what the plan says — which `F7` toggles.
    /// </summary>
    private WifiSecurity Security =>
        OnHidden || _list.Selected >= _found.Count
            ? (_plan.Network.Wifi?.Security ?? WifiSecurity.Psk)
            : (_found[_list.Selected].Security ?? WifiSecurity.Psk);

    public override string Status =>
        "TAB=Next field   F6=Rescan   F4=Test   ENTER=Continue   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        string iface = _plan.Network.Interface ?? "this computer";
        if (!_scanned)
        {
            f.Body(3, 5, $"Setup is scanning for wireless networks on {iface} …");
            return;
        }

        f.Body(3, 5, $"Setup found these wireless networks on {iface}.");
        KeepFocusValid();

        int left = f.Left + 5;
        int width = f.BoxWidth;
        int fieldWidth = Math.Min(40, width - 24);

        _list.Draw(f, 5, left, width);
        f.Text(5, left + 2, " Network ",
               _field == Field.List ? Slot.Black : Slot.White,
               _field == Field.List ? Slot.Grey : Slot.Field);

        bool enterprise = Security == WifiSecurity.Enterprise;

        f.Box(11, left, width, enterprise ? 9 : 5);
        int row = 12;
        if (OnHidden)
        {
            Row(f, row, left, fieldWidth, "Network name:", _ssid, Field.Ssid);
            row += 2;
        }
        else
        {
            f.Text(row, left + 3, "Authentication:");
            f.Text(row, left + 21, enterprise ? "PEAP / MSCHAPv2" : "WPA2/WPA3 Personal");
            row += 2;
        }

        if (enterprise)
        {
            Row(f, row, left, fieldWidth, "Identity:", _identity, Field.Identity);
            Row(f, row + 2, left, fieldWidth, "Password:", _secret, Field.Secret);
            Row(f, row + 4, left, fieldWidth, "CA certificate:", _cacert, Field.CaCert);
            // L27 IS PRINTED, NOT DEFAULTED. There is no certificate store in
            // 80×25, so an empty CA field means the RADIUS server is not
            // verified — and that has to be where the operator is looking.
            f.Body(20, 5,
                   _cacert.Length == 0
                       ? "No CA certificate: the network will NOT be verified."
                       : "The RADIUS server will be verified against that certificate.",
                   _cacert.Length == 0 ? Slot.Brand : Slot.White);
        }
        else
        {
            Row(f, row, left, fieldWidth, "Passphrase:", _secret, Field.Secret);
            f.Body(17, 5, "Setup will associate now and report whether it worked.");
        }

        // Row 21 on both, and never 22: the status bar is the last row of the
        // frame and a body line under it is a line nobody sees.
        int noteRow = enterprise ? 21 : 19;
        if (_note is not null)
            f.Body(noteRow, 5, _note, _noteIsGood ? Slot.White : Slot.Brand);
        else if (_plan.Network.Verified)
            f.Body(noteRow, 5, $"Tested: {_plan.Network.VerifiedDetail}");
        else
            f.Body(noteRow, 5, "Not yet tested.", Slot.Brand);
    }

    private void Row(Frame f, int row, int left, int width, string label,
                     TextBox box, Field which)
    {
        f.Text(row, left + 3, label);
        box.Draw(f, row, left + 21, width, _field == which);
    }

    /// <summary>The fields that exist right now, in TAB order.</summary>
    private List<Field> Fields()
    {
        var fields = new List<Field> { Field.List };
        if (OnHidden) fields.Add(Field.Ssid);
        fields.Add(Field.Secret);
        if (Security == WifiSecurity.Enterprise)
        {
            fields.Insert(fields.Count - 1, Field.Identity);
            fields.Add(Field.CaCert);
        }
        return fields;
    }

    /// <summary>
    /// Keep the focus on a field that is actually on the screen.
    ///
    /// WHICH FIELDS EXIST CHANGES WITH THE SELECTION. Moving from an enterprise
    /// network to a PSK one removes Identity and CA certificate; moving off the
    /// hidden-network row removes the SSID field. Without this, the focus stays
    /// on a field that is no longer drawn, and keystrokes go into an invisible
    /// TextBox — the field shows nothing, the caret is nowhere, and the value is
    /// still there to be committed. It looks exactly like a keyboard that has
    /// stopped working.
    /// </summary>
    private void KeepFocusValid()
    {
        if (!Fields().Contains(_field)) _field = Field.List;
    }

    public override Transition Handle(KeyPress key)
    {
        // The first idle tick is the scan. SetupFlow passes Key.None through
        // only for a screen that opted in with `Ticks`, so this arrives exactly
        // once — after the "scanning" frame is already on the console.
        if (!_scanned)
        {
            _scanned = true;
            Rescan();
            return Transition.Redraw;
        }

        KeepFocusValid();
        switch (key.Key)
        {
            case Key.Tab:
            {
                List<Field> fields = Fields();
                int at = fields.IndexOf(_field);
                _field = fields[(Math.Max(0, at) + 1) % fields.Count];
                _note = null;
                return Transition.Redraw;
            }

            case Key.F6:
                _note = "Scanning …";
                Rescan();
                return Transition.Redraw;

            case Key.F7 when OnHidden:
                // A hidden network does not say what it is, so this is the one
                // place the operator has to. Not offered for a scanned network:
                // the access point already answered, and letting the screen
                // disagree with the radio would only produce associations that
                // fail for a reason nothing on screen explains.
                WifiPlan hw = _plan.Network.Wifi ??= new WifiPlan();
                hw.Security = hw.Security == WifiSecurity.Psk
                    ? WifiSecurity.Enterprise : WifiSecurity.Psk;
                return Transition.Redraw;

            case Key.F4:
                if (!Collect()) return Transition.Redraw;
                (bool ok, string detail) = NetworkProbe.Test(_plan);
                _note = detail;
                _noteIsGood = ok;
                return Transition.Redraw;

            case Key.Escape:
                return Transition.Back;

            case Key.Enter:
                if (!Collect()) return Transition.Redraw;
                // 9S next when the address is static, because a static address
                // on a network you have not joined cannot be tested.
                if (_plan.Network.Method == NetworkMethod.Static)
                    return Transition.To(new StaticScreen(_plan));
                return Transition.To(ExecuteScreen.Start(_plan));

            default:
                if (_field == Field.List)
                {
                    if (!_list.Handle(key)) return Transition.Stay;
                    _note = null;
                    return Transition.Redraw;
                }
                var box = _field switch
                {
                    Field.Ssid => _ssid,
                    Field.Identity => _identity,
                    Field.CaCert => _cacert,
                    _ => _secret,
                };
                if (!box.Handle(key)) return Transition.Stay;
                _note = null;
                return Transition.Redraw;
        }
    }

    /// <summary>
    /// What THIS screen collected. The whole-plan check is at ExecuteScreen.Start.
    /// </summary>
    private bool Collect()
    {
        WifiPlan w = _plan.Network.Wifi ??= new WifiPlan();

        if (OnHidden)
        {
            w.Ssid = _ssid.Value.Trim();
            w.Hidden = true;
            // Security stays whatever F7 left it as: there is no scan result to
            // read it off.
        }
        else if (_list.Selected < _found.Count)
        {
            WifiNetwork net = _found[_list.Selected];
            w.Ssid = net.Ssid;
            w.Hidden = false;
            w.Security = net.Security ?? WifiSecurity.Psk;
        }

        if (w.Ssid.Length == 0)
        {
            _note = "Choose a network, or type the name of a hidden one.";
            _noteIsGood = false;
            return false;
        }

        if (w.Security == WifiSecurity.Enterprise)
        {
            w.Identity = _identity.Value.Trim();
            w.Password = _secret.Value;
            w.CaCertificate = _cacert.Value.Trim() is { Length: > 0 } ca ? ca : null;
            w.Psk = null;
            if (w.Identity.Length == 0) { _note = "802.1X needs an identity."; _noteIsGood = false; return false; }
            if (w.Password.Length == 0) { _note = "802.1X needs a password."; _noteIsGood = false; return false; }
        }
        else
        {
            w.Psk = _secret.Value;
            w.Identity = null;
            w.Password = null;
            if (w.Psk.Length is < WifiPlan.MinimumPsk or > WifiPlan.MaximumPsk)
            {
                _note = $"A WPA passphrase is {WifiPlan.MinimumPsk} to "
                        + $"{WifiPlan.MaximumPsk} characters.";
                _noteIsGood = false;
                return false;
            }
        }

        // THE SECRET IS NOT LOGGED, and neither is its length for the PSK — a
        // length in a log that is also on a screendump is most of a passphrase.
        Log.Info($"wireless: '{w.Ssid}' {w.Security}" + (w.Hidden ? " (hidden)" : ""));
        return true;
    }
}
