using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 12 — Setup is complete. SETUP-PLAN §3, Win2k's restart prompt.
///
/// Phase 1 is STRICTLY NON-DESTRUCTIVE, so this screen says what actually
/// happened rather than what it will eventually say. That distinction is the
/// whole point: a skeleton that claims to have installed something is worse
/// than no skeleton, and the deliverable for this phase is "you can walk the
/// whole flow in a VM and it looks right" — not "it looks finished".
///
/// The plan is printed to the log on the way in, which makes the walk verifiable
/// from a serial console without reading pixels.
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
        f.Body(3, 5, "Setup has collected the settings below.");

        int left = f.Left + 5;
        int width = Math.Min(70, f.BodyWidth - 10);
        f.Box(5, left, width, 6);
        f.Text(6, left + 3, $"Intent:      {_plan.Intent}");
        f.Text(7, left + 3, $"Language:    {_plan.Language}");
        f.Text(8, left + 3, $"Keyboard:    {_plan.Keyboard}");
        f.Text(9, left + 3, $"Time zone:   {_plan.Timezone}");

        // Stated in the brand colour and in the plainest words available. This
        // is the sentence that stops someone concluding a machine was installed.
        f.Body(12, 5, "NOTHING HAS BEEN WRITTEN TO ANY DISK.", Slot.Brand);
        f.Body(14, 5, "This is the Phase 1 skeleton of OS/7 Setup. Storage, accounts and");
        f.Body(15, 5, "the bootloader are not implemented yet, so no partition was created");
        f.Body(16, 5, "and no data was changed.");
        f.Body(18, 5, $"A log of this session is at {Log.Path}.");
    }

    public override Transition Handle(KeyPress key) =>
        key.Key == Key.Enter ? Transition.Finish : Transition.Stay;
}
