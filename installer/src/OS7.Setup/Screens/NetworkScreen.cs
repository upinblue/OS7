using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Steps;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 9 — the network adapter and how it gets an address. SETUP-PLAN §3.
///
/// IT SITS AFTER SCREEN 8, AND THAT ORDERING IS LOAD-BEARING (D14). The netplan
/// renderer is a function of the install mode, so the network cannot be asked
/// before the mode is known — writing a file whose backend has not been chosen
/// yet is the same class of mistake as screen 6 validating an account nobody had
/// typed (BUILD-NOTES #45).
///
/// IT IS ALSO NOT OPTIONAL, and that changed on evidence rather than on taste.
/// L23: the shipped image has an empty `/etc/netplan`, an empty
/// `/etc/systemd/network`, no `cloud-init` and no enabled `systemd-networkd`.
/// Before this screen existed, every headless install produced a machine with no
/// network and nobody had chosen that.
///
/// TWO LISTS AND A TAB, because the adapter and the method are two questions
/// whose answers have to be visible at once: "static on which port" is the whole
/// content of the screen, and splitting it into two screens would mean seeing
/// one half at a time.
/// </summary>
internal sealed class NetworkScreen : Screen
{
    private readonly InstallPlan _plan;
    private readonly List<NetworkLink> _links;
    private readonly SelectionList _adapters;
    private readonly SelectionList _methods;

    private enum Focus { Adapter, Method }
    private Focus _focus = Focus.Adapter;

    private string? _note;
    private bool _noteIsGood;

    /// <summary>The order of the method list, so an index is never a literal.</summary>
    private static readonly NetworkMethod[] Methods =
        { NetworkMethod.Dhcp, NetworkMethod.Static, NetworkMethod.None };

    public NetworkScreen(InstallPlan plan) : this(plan, NetworkLinks.Enumerate()) { }

    /// <summary>
    /// The adapter list is HANDED IN, so `Entry` and the constructor cannot
    /// disagree about what is on the machine.
    ///
    /// The first version enumerated twice — once in `Entry` to decide whether
    /// the screen applies at all, once here to fill the list. Two reads of
    /// /sys/class/net a few milliseconds apart, and a USB adapter unplugged
    /// between them would have produced a screen offering a list its own
    /// existence check had not seen.
    /// </summary>
    private NetworkScreen(InstallPlan plan, List<NetworkLink> links)
    {
        _plan = plan;
        _links = links;

        int width = SelectionList.TextWidth(Frame.BoxWidthFor(80));
        var rows = _links.Count > 0
            ? _links.Select(l => l.Row(width)).ToList()
            : new List<string> { "(no network adapter was found on this computer)" };

        // Pre-selected from the plan when there is one - stepping back into this
        // screen has to show what was chosen. Otherwise the first adapter, which
        // NetworkLinks.Enumerate has already sorted so that a wired adapter with
        // a cable in it comes first.
        int at = 0;
        if (!string.IsNullOrEmpty(plan.Network.Interface))
        {
            int found = _links.FindIndex(l => l.Name == plan.Network.Interface);
            if (found >= 0) at = found;
        }
        _adapters = new SelectionList(rows, visibleRows: 3, selected: at);

        _methods = new SelectionList(
            new List<string>
            {
                "Obtain an address automatically (DHCP)",
                "Specify an address (static TCP/IP)",
                "Leave this computer without a network connection",
            },
            visibleRows: 3,
            selected: Math.Max(0, Array.IndexOf(Methods, plan.Network.Method)));
    }

    private bool HaveAdapters => _links.Count > 0;

    private NetworkLink? Chosen =>
        HaveAdapters && _adapters.Selected < _links.Count ? _links[_adapters.Selected] : null;

    private NetworkMethod ChosenMethod => Methods[_methods.Selected];

    public override string Status =>
        "TAB=Next list   F4=Test   ENTER=Continue   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Setup can configure this computer's network connection now.");

        int left = f.Left + 5;
        int width = f.BoxWidth;

        _adapters.Draw(f, 5, left, width);
        _methods.Draw(f, 11, left, width);

        // Which list has the keys, written into the box's top border. Without
        // it the two boxes are identical and the arrow keys look like they are
        // moving the wrong one — which is the entire failure mode of a screen
        // with two lists on it.
        Caption(f, 5, left, " Adapter ", _focus == Focus.Adapter);
        Caption(f, 11, left, " Method ", _focus == Focus.Method);

        if (ChosenMethod == NetworkMethod.None)
        {
            f.Body(17, 5, "This computer will be installed with no network configuration.");
            f.Body(18, 5, "Nothing will be written to /etc/netplan.");
        }
        else
        {
            f.Body(17, 5, "Setup will apply these settings now and test them before");
            f.Body(18, 5, "writing them to the installed system. Press T to test.");
        }

        if (_note is not null)
            f.Body(20, 5, _note, _noteIsGood ? Slot.White : Slot.Brand);
        else if (_plan.Network.Verified)
            f.Body(20, 5, $"Tested: {_plan.Network.VerifiedDetail}");
        else if (ChosenMethod != NetworkMethod.None)
            f.Body(20, 5, "Not yet tested.", Slot.Brand);
    }

    private static void Caption(Frame f, int row, int left, string text, bool focused)
    {
        f.Text(row, left + 2, text,
               focused ? Slot.Black : Slot.White,
               focused ? Slot.Grey : Slot.Field);
    }

    public override Transition Handle(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Tab:
                _focus = _focus == Focus.Adapter ? Focus.Method : Focus.Adapter;
                _note = null;
                return Transition.Redraw;

            case Key.Escape:
                return Transition.Back;

            // F4 = apply it here and now, and say what actually happened (D12).
            // The live medium has the whole stack; the installed machine does
            // not exist yet. This is the only moment a mistyped address or a
            // wrong passphrase can be caught by the person who typed it.
            //
            // AN F-KEY AND NOT `T`, on all three network screens. SelectionList
            // consumes letters for type-to-find and TextBox consumes them as
            // text, so `T` would mean two things depending on where the cursor
            // was — the one property a keyboard-driven installer cannot afford,
            // and the reason SetupFlow handles F3 and F5 itself.
            case Key.F4:
                return Test();

            case Key.Enter:
                return Commit();

            default:
                var list = _focus == Focus.Adapter ? _adapters : _methods;
                if (!list.Handle(key)) return Transition.Stay;
                _note = null;
                return Transition.Redraw;
        }
    }

    /// <summary>
    /// Write what this screen collected into the plan, and refuse only what this
    /// screen could have got right.
    ///
    /// BUILD-NOTES #45 in its general form. The Wi-Fi network and the static
    /// addresses are collected on 9W and 9S, so this screen must not ask whether
    /// they are set — at the moment ENTER is pressed here, nobody has been asked.
    /// </summary>
    private bool Collect()
    {
        NetworkPlan n = _plan.Network;
        n.Method = ChosenMethod;

        if (n.Method == NetworkMethod.None)
        {
            // An explicit choice, and the rest of the plan is cleared so that a
            // half-typed address from a previous pass cannot survive into a
            // machine that was chosen to have no network.
            n.Interface = null;
            n.Kind = LinkKind.Wired;
            n.Wifi = null;
            n.Address = null;
            n.Gateway = null;
            n.Nameservers.Clear();
            n.Search.Clear();
            Log.Info("network: none (chosen)");
            return true;
        }

        NetworkLink? link = Chosen;
        if (link is null)
        {
            _note = "There is no network adapter to configure. Choose the last option.";
            _noteIsGood = false;
            return false;
        }

        n.Interface = link.Name;
        n.Kind = link.Kind;
        // A wired adapter cannot carry a wireless network, and stepping back
        // from 9W to pick an Ethernet port has to drop it rather than leave it
        // for InstallPlan.Validate to complain about several screens later.
        if (link.Kind == LinkKind.Wired) n.Wifi = null;
        else n.Wifi ??= new WifiPlan();

        Log.Info($"network: {n.Interface} ({n.Kind}), method {n.Method}");
        return true;
    }

    private Transition Test()
    {
        if (!Collect()) return Transition.Redraw;

        if (_plan.Network.Method == NetworkMethod.None)
        {
            _note = "There is nothing to test: this computer will have no network.";
            _noteIsGood = false;
            return Transition.Redraw;
        }

        // The later screens have not run yet, so a static configuration has no
        // address and a wireless one has no network. Say which screen has it
        // rather than reporting a failure that is really "not asked yet".
        if (_plan.Network.Method == NetworkMethod.Static
            && string.IsNullOrWhiteSpace(_plan.Network.Address))
        {
            _note = "Press ENTER first: the addresses are typed on the next screen.";
            _noteIsGood = false;
            return Transition.Redraw;
        }
        if (_plan.Network.Kind == LinkKind.Wireless
            && string.IsNullOrWhiteSpace(_plan.Network.Wifi?.Ssid))
        {
            _note = "Press ENTER first: the wireless network is chosen on the next screen.";
            _noteIsGood = false;
            return Transition.Redraw;
        }

        (bool ok, string detail) = NetworkProbe.Test(_plan);
        _note = detail;
        _noteIsGood = ok;
        return Transition.Redraw;
    }

    private Transition Commit()
    {
        if (!Collect()) return Transition.Redraw;
        return Transition.To(Next(_plan));
    }

    /// <summary>
    /// Where screen 9 goes, and where screen 8 comes in.
    ///
    /// The branch lives here rather than in each screen, so that the sequence
    /// 9 → 9W → 9S → execute is written once and every entry point uses it.
    /// Wireless first: a static address on a network you have not joined cannot
    /// be tested, so 9W runs before 9S.
    /// </summary>
    public static Screen Next(InstallPlan plan)
    {
        NetworkPlan n = plan.Network;
        if (n.Method != NetworkMethod.None)
        {
            if (n.Kind == LinkKind.Wireless) return new WifiScreen(plan);
            if (n.Method == NetworkMethod.Static) return new StaticScreen(plan);
        }
        // Start, not `new`: the whole-plan check lives behind that factory and
        // the constructor is private. This is the last ENTER before a disk is
        // written on every path that does not go through 9W or 9S.
        return ExecuteScreen.Start(plan);
    }

    /// <summary>
    /// The screen after 8, or the one after that where there is nothing to ask.
    ///
    /// Called by ModeScreen for the same reason ModeScreen.Next is called by
    /// screen 7: the question "is there anything to ask here" belongs to the
    /// screen that would ask it. A machine with no network hardware at all is a
    /// real machine — an air-gapped appliance, a board with the NIC disabled in
    /// firmware — and showing it a list with one apologetic row is worse than
    /// not stopping.
    /// </summary>
    public static Screen Entry(InstallPlan plan)
    {
        List<NetworkLink> links = NetworkLinks.Enumerate();
        if (links.Count > 0) return new NetworkScreen(plan, links);

        plan.Network.Method = NetworkMethod.None;
        plan.Network.Interface = null;
        Log.Info("network: none (no adapter on this machine; screen 9 skipped)");
        // The SAME door as every other path. A skipped screen must not also skip
        // the gate behind it — that is BUILD-NOTES #45 read from the other end.
        return ExecuteScreen.Start(plan);
    }
}
