using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 1 — Welcome to Setup. SETUP-PLAN §3.1, transcribed.
///
/// `R` is the interesting key. Win2k's R=Repair maps almost exactly onto a ZFS
/// concept: import an existing rpool and install into a NEW boot environment
/// beside the current one, leaving rpool/USERDATA untouched. That is an
/// upgrade/repair path Calamares would never have given us, and it is Phase 6 —
/// so here it records the intent on the plan and says so rather than pretending.
/// </summary>
internal sealed class WelcomeScreen : Screen
{
    private readonly InstallPlan _plan;
    private string? _note;

    public WelcomeScreen(InstallPlan plan) => _plan = plan;

    public override string Status => "ENTER=Continue   R=Repair   F3=Quit";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Welcome to Setup.");
        f.Body(5, 5, "This portion of the Setup program prepares OS/7 to run on your");
        f.Body(6, 5, "computer.");
        f.Body(8, 7, "• To set up OS/7 now, press ENTER.");
        f.Body(10, 7, "• To repair or extend an existing OS/7 installation, press R.");
        f.Body(12, 7, "• To quit Setup without installing OS/7, press F3.");
        if (_note is not null) f.Body(15, 5, _note, Slot.Brand);

        // The identity, in full, on the first screen — the title row carries the
        // number on every screen but only this one has room to say what is under
        // it. Which archive snapshot the base came from is the difference
        // between "OS/7 1.0.0.32" naming a product and naming a STATE
        // (RELEASE-AND-UPDATE-PLAN §3.1), and it is the second thing a support
        // case needs after the version itself.
        Release r = Release.Current;
        f.Body(17, 5, r.Display);
        if (r.Known)
        {
            string based = r.BaseRelease is null ? "" : $"Ubuntu {r.BaseRelease} base";
            string pin   = r.ArchiveSnapshot is null
                ? "archive not pinned"
                : $"archive {r.ArchiveSnapshot}";
            f.Body(18, 5, based.Length > 0 ? $"{based}, {pin}" : pin);

            // Said on the screen and not only in the log. A build whose source
            // could not be identified may still be perfectly good, but two of
            // them can carry one number and different bits - so the one place it
            // must not be quiet is the screen somebody photographs for a ticket.
            if (!r.Reproducible)
                f.Body(19, 5, "This build was not made from a clean source tree.", Slot.Brand);
        }
    }

    public override Transition Handle(KeyPress key)
    {
        if (key.Key == Key.Enter)
        {
            _plan.Intent = Intent.Install;
            Log.Info("intent: install");
            return Transition.To(new LicenceScreen(_plan));
        }
        if (key.Is('R'))
        {
            // Recorded rather than refused: the plan is the thing screens edit
            // (§6.6), and an intent Phase 6 will honour is still worth carrying.
            _plan.Intent = Intent.Repair;
            Log.Info("intent: repair (not implemented before Phase 6)");
            _note = "Repair is not available yet. Press ENTER to set up OS/7 instead.";
            return Transition.Redraw;
        }
        return Transition.Stay;
    }
}
