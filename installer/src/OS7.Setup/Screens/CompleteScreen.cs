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
        int width = Math.Min(70, f.BodyWidth - 10);
        StoragePlan s = _plan.Storage;

        f.Box(5, left, width, 11);
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

        f.Body(17, 5, "Remove the setup medium and press ENTER to restart.");
        if (s.Encrypt)
            f.Body(19, 5, "This computer will ask for the disk passphrase when it starts.",
                   Slot.Brand);
        f.Body(21, 5, $"A log of this session is at {Log.Path}.");
    }

    public override Transition Handle(KeyPress key) =>
        key.Key == Key.Enter ? Transition.Finish : Transition.Stay;
}
