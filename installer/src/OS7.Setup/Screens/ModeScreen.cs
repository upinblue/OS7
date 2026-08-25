using System.Runtime.InteropServices;
using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 8 — GUI or headless. SETUP-PLAN §3, and **amd64 only**.
///
/// README makes this an install-time choice over ONE shared package base per
/// architecture: the image carries the desktop and headless removes it, offline.
/// The consequence that makes it a real choice rather than a preference is
/// Intune: supported Linux enrolment requires GNOME, so headless machines are
/// managed through Azure Arc instead. The screen says that, because it is the
/// difference between two management stories and not a matter of taste.
///
/// ON arm64 THIS SCREEN DOES NOT APPEAR AT ALL. arm64 is server-only (README):
/// Microsoft ships no arm64 Linux Edge and `intune-portal` /
/// `microsoft-identity-broker` are x86_64-only, so an arm64 GUI could never have
/// been Intune-enrolled. There is no desktop in the image to keep or remove, and
/// a screen offering a choice that does not exist is worse than no screen.
/// </summary>
internal sealed class ModeScreen : Screen
{
    private readonly InstallPlan _plan;
    private readonly SelectionList _list;

    /// <summary>
    /// Whether there is a choice to make on this machine.
    ///
    /// From the RUNNING architecture, not from the plan: Setup installs the
    /// machine it is running on, and the image it is installing from is the one
    /// it booted. Asking the plan would let a plan file written on amd64 offer a
    /// desktop that is not on this medium.
    /// </summary>
    public static bool Applies =>
        RuntimeInformation.OSArchitecture != Architecture.Arm64;

    public ModeScreen(InstallPlan plan)
    {
        _plan = plan;
        _list = new SelectionList(
            new List<string>
            {
                "Desktop  - GNOME, and eligible for Microsoft Intune enrolment",
                "Headless - no desktop; managed through Azure Arc",
            },
            visibleRows: 2,
            selected: plan.Mode == InstallMode.Gui ? 0 : 1);
    }

    public override string Status => "ENTER=Continue   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Choose how this computer will be used.");
        f.Body(5, 5, "Use the UP and DOWN ARROW keys to select, then press ENTER.");

        int left = f.Left + 5;
        int width = f.BoxWidth;
        _list.Draw(f, 7, left, width);

        f.Body(12, 5, "Desktop installs GNOME from this medium. It is the only mode");
        f.Body(13, 5, "Microsoft Intune can enrol, because supported Linux enrolment");
        f.Body(14, 5, "requires a GNOME session.");
        f.Body(16, 5, "Headless removes the desktop. Nothing is downloaded either way -");
        f.Body(17, 5, "both modes come from the medium Setup booted from.");
    }

    public override Transition Handle(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Enter:
                _plan.Mode = _list.Selected == 0 ? InstallMode.Gui : InstallMode.Headless;
                Log.Info($"install mode: {_plan.Mode}");
                // Start, not `new`: the whole-plan check lives behind that
                // factory and the constructor is private so it cannot be walked
                // round. This is the last ENTER before a disk is written.
                return Transition.To(ExecuteScreen.Start(_plan));

            case Key.Escape:
                return Transition.Back;

            default:
                return _list.Handle(key) ? Transition.Redraw : Transition.Stay;
        }
    }

    /// <summary>
    /// The next screen, skipping this one where it does not apply.
    ///
    /// Called by screen 7 rather than having screen 7 know about architectures:
    /// the question "is there a mode to choose" belongs to the screen that would
    /// ask it.
    /// </summary>
    public static Screen Next(InstallPlan plan)
    {
        if (Applies) return new ModeScreen(plan);

        // arm64: server-only, and the plan says so rather than defaulting
        // silently. Nothing later has to re-derive it.
        plan.Mode = InstallMode.Headless;
        Log.Info("install mode: Headless (arm64 is server-only; screen 8 skipped)");
        // The SAME door as the branch above. A skipped screen must not also skip
        // the gate behind it, and this is the arm64 path - the only one anything
        // has ever been installed through.
        return ExecuteScreen.Start(plan);
    }
}
