using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 12 — Setup is complete. SETUP-PLAN §3, Win2k's restart prompt.
///
/// It says what actually happened, not what it will eventually say. Through
/// Phase 2 that meant admitting there was no operating system on the disk; at
/// Phase 3 there is one, it has an account, and the bootloader is installed — so
/// this screen now offers a restart, which is the first time it honestly can.
///
/// The care that went into the Phase 2 wording is still the point: a screen
/// reading "Setup is complete" over a disk that cannot boot would be the single
/// most expensive sentence in this installer. It is only allowed to say it
/// because BootloaderStep checked the menu resolves a boot environment and
/// InitramfsStep checked the startup image can unlock and import.
/// </summary>
internal sealed class CompleteScreen : Screen
{
    private readonly InstallPlan _plan;

    public CompleteScreen(InstallPlan plan)
    {
        _plan = plan;
        Log.Info("plan: " + _plan.ToJson().ReplaceLineEndings(" "));
    }

    public override string Status => "ENTER=Restart   F3=Quit to a shell";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Setup has prepared this computer as follows.");

        int left = f.Left + 5;
        int width = f.BoxWidth;
        StoragePlan s = _plan.Storage;

        f.Box(5, left, width, 12);
        // The version comes FIRST, and it is here as well as on the title row
        // because this is the screen someone reads when the install is over: it
        // is the record of what was put on this machine, and the boot
        // environment on the disk is named after this exact number.
        f.Text(6, left + 3, $"OS/7 version: {Release.Current.Short}");
        f.Text(7, left + 3, $"Language:     {_plan.Language}");
        f.Text(8, left + 3, $"Keyboard:     {_plan.Keyboard}");
        f.Text(9, left + 3, $"Time zone:    {_plan.Timezone}");
        f.Text(10, left + 3, $"Disk:         {s.Disk ?? "(none)"}");
        f.Text(11, left + 3, $"Encryption:   {(s.Encrypt ? "LUKS2 (passphrase set)" : "none")}");
        f.Text(12, left + 3, $"Swap:         {s.Swap}");
        f.Text(13, left + 3, $"Computer:     {_plan.Account.Hostname}");
        f.Text(14, left + 3, $"Account:      {_plan.Account.Username}"
                             + (_plan.Mode == InstallMode.Gui ? "   (desktop)" : "   (headless)"));
        f.Text(15, left + 3, $"Network:      {NetworkLine()}");

        f.Body(18, 5, "Remove the setup medium and press ENTER to restart.");
        if (s.Encrypt)
            f.Body(19, 5, "This computer will ask for the disk passphrase when it starts.",
                   Slot.Brand);

        // AN UNTESTED NETWORK IS SAID OUT LOUD, on the last screen anybody reads.
        //
        // D12 makes the live test optional on purpose - a machine built on a
        // bench for a site that is not wired yet has to be installable. What
        // must not happen is that it goes out with an untested configuration and
        // nothing anywhere says so, because the machine this matters for is the
        // headless one that nobody can look at afterwards.
        NetworkPlan n = _plan.Network;
        if (n.Method != NetworkMethod.None && !n.Verified)
            f.Body(20, 5, "The network settings were NOT tested before they were written.",
                   Slot.Brand);
        else if (n.Method == NetworkMethod.None)
            f.Body(20, 5, "This computer has no network configuration.", Slot.Brand);

        // THE PATH THAT WILL STILL EXIST AFTER THE RESTART THIS SCREEN OFFERS.
        //
        // Until 2026-08-25 this named `Log.Path`, which is on the live medium's
        // RAM overlay — so the sentence was true when it was read and false one
        // keypress later, and it was false in exactly the case where somebody
        // would go looking: a machine that came up wrong (L31).
        //
        // `Log.Kept` and not `Log.Installed`, because it is null when the copy
        // did not happen. A screen that names a path from a constant is a screen
        // that cannot be wrong on purpose.
        if (Log.Kept is not null)
            f.Body(21, 5, $"A record of this installation is at {Log.Kept}.");
        else
        {
            f.Body(21, 5, "Setup could not save its log onto this computer.", Slot.Brand);
            f.Body(22, 5, $"It is at {Log.Path} until the restart, and no longer.",
                   Slot.Brand);
        }
    }

    /// <summary>
    /// The network, in one line and in the terms the operator typed.
    ///
    /// The ADDRESS where there is one, not the word "static": this screen is the
    /// record of what was put on the machine, and "static" does not tell anybody
    /// which machine to look for on the network afterwards.
    /// </summary>
    private string NetworkLine()
    {
        NetworkPlan n = _plan.Network;
        if (n.Method == NetworkMethod.None) return "none";

        string where = n.Kind == LinkKind.Wireless && n.Wifi is not null
            ? $"{n.Interface} '{n.Wifi.Ssid}'"
            : n.Interface ?? "(none)";
        string how = n.Method == NetworkMethod.Static ? n.Address ?? "static" : "DHCP";
        return $"{where}  {how}";
    }

    public override Transition Handle(KeyPress key) =>
        key.Key == Key.Enter ? Transition.Finish : Transition.Stay;
}
