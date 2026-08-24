using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 12 — Setup is complete. SETUP-PLAN §3, Win2k's restart prompt.
///
/// It says what actually happened, not what it will eventually say. At Phase 2
/// the disk has been partitioned, encrypted and given its pools and datasets —
/// and there is no operating system on it, because copying the system, the
/// accounts and the bootloader are Phase 3. A screen that read "Setup is
/// complete" over a disk that cannot boot would be the single most expensive
/// sentence in this installer.
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

        f.Box(5, left, width, 8);
        f.Text(6, left + 3, $"Language:    {_plan.Language}");
        f.Text(7, left + 3, $"Keyboard:    {_plan.Keyboard}");
        f.Text(8, left + 3, $"Time zone:   {_plan.Timezone}");
        f.Text(9, left + 3, $"Disk:        {s.Disk ?? "(none)"}");
        f.Text(10, left + 3, $"Encryption:  {(s.Encrypt ? "LUKS2 (passphrase set)" : "none")}");
        f.Text(11, left + 3, $"Swap:        {s.Swap}");

        // The half that has NOT happened, in the brand colour, because it is the
        // sentence that stops someone rebooting into a disk with nothing on it.
        f.Body(14, 5, "NO OPERATING SYSTEM HAS BEEN COPIED TO THIS DISK YET.", Slot.Brand);
        f.Body(16, 5, "Setup is at Phase 2: the disk is partitioned, encrypted and carries");
        f.Body(17, 5, "empty ZFS pools. Copying the system, creating accounts and installing");
        f.Body(18, 5, "the bootloader are Phase 3, and this computer will not boot from it");
        f.Body(19, 5, "until they exist.");
        f.Body(21, 5, $"A log of this session is at {Log.Path}.");
    }

    public override Transition Handle(KeyPress key) =>
        key.Key == Key.Enter ? Transition.Finish : Transition.Stay;
}
