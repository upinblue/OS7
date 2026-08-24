using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 4 — Select a disk. SETUP-PLAN §3.1, transcribed.
///
/// Every disk is LISTED, including the ones Setup refuses; the refusal is shown
/// next to the disk. L12 requires that of the setup medium — "listed but never
/// selectable" — and the same shape covers a mounted disk and a disk too small
/// for the §4.4 layout. Hiding a disk makes Setup look broken to whoever is
/// standing in front of the machine that has it.
/// </summary>
internal sealed class DiskScreen : Screen
{
    private readonly InstallPlan _plan;
    private readonly List<Disk> _disks;
    private SelectionList _list;
    private string? _note;

    /// <summary>
    /// The disk whose existing installation has been named to the operator and
    /// is one more ENTER away from being erased. Held per DISK NAME rather than
    /// as a bool, so that arrowing away to another disk and back asks again —
    /// a confirmation that survives changing what is being confirmed is not a
    /// confirmation.
    /// </summary>
    private string? _confirming;

    /// <summary>What the probe found, kept so the log can say what was replaced.</summary>
    private ExistingInstall? _existing;

    public DiskScreen(InstallPlan plan)
    {
        _plan = plan;
        _disks = Disks.Enumerate();
        _visible = 10;
        // Start on the plan's disk when there is one - an --unattend plan
        // replayed interactively, or a step back from screen 5.
        _list = Build(_visible, _width,
                      Math.Max(0, _disks.FindIndex(d => d.StablePath == _plan.Storage.Disk)));
    }

    private int _visible;

    /// <summary>
    /// The box width the rows were last built for.
    ///
    /// Draw decides how much room the box has on the screen; Build decides how
    /// much text goes in its rows. They did not agree: Build passed a literal
    /// 66, which was the row width of the box Draw happened to draw. Nothing
    /// checks that, and nothing complains — an over-long row is simply cut — so
    /// the disagreement surfaced as the right-hand column of screen 4 losing its
    /// last character. Both now ask <see cref="Frame.BoxWidthFor"/>.
    /// </summary>
    private int _width = Frame.BoxWidthFor(80);

    private SelectionList Build(int rows, int width, int selected)
    {
        int room = SelectionList.TextWidth(width);
        var labels = new List<string>();
        foreach (Disk d in _disks) labels.Add(d.Describe(room));
        if (labels.Count == 0) labels.Add("(no disks found)");
        return new SelectionList(labels, rows, selected);
    }

    /// <summary>
    /// Resize the list, and ONLY when the size actually changed.
    ///
    /// Layout() is called before every repaint, and a repaint happens on every
    /// keypress. Rebuilding the list here unconditionally therefore reset the
    /// selection to the plan's disk on every redraw — so pressing DOWN moved the
    /// highlight and the next frame put it straight back. The disk could not be
    /// changed at all, and the screen looked like a keyboard that was not
    /// working rather than like a bug.
    /// </summary>
    public override void Layout(int cols, int rows)
    {
        int visible = Math.Clamp(rows - 13, 3, Math.Max(3, _disks.Count));
        int width = Frame.BoxWidthFor(cols);
        // The WIDTH is watched as well as the height. The rows are cut to fit
        // the box, so a console that changes width and does not change height —
        // which is what loading a different console font does — would otherwise
        // leave every row built for the width before it.
        if (visible == _visible && width == _width) return;
        _visible = visible;
        _width = width;
        _list = Build(visible, width, _list.Selected);
    }

    public override string Status => "ENTER=Select   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Setup will install OS/7 on the disk selected below.");
        f.Body(5, 5, "Use the UP and DOWN ARROW keys to select a disk, then press ENTER.");

        int left = f.Left + 5;
        _list.Draw(f, 7, left, f.BoxWidth);

        int after = 7 + _list.Height + 1;
        // The warning goes UNDER the list and above the keys, which is where
        // Win2k put it: the last thing read before ENTER is pressed.
        f.Body(after, 5, "Every partition on the selected disk will be destroyed.");
        if (_note is not null) f.Body(after + 2, 5, _note, Slot.Brand);
    }

    public override Transition Handle(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Enter when _disks.Count > 0:
                Disk chosen = _disks[_list.Selected];
                if (!chosen.Selectable)
                {
                    // Refused with the reason, not ignored. A key that appears to
                    // do nothing is indistinguishable from a hung installer.
                    // The DETAIL, not the marker: this is the line with room for
                    // the mount point the row's last column could not carry.
                    _note = $"{chosen.Name} cannot be used: {chosen.Blocker!.Detail}.";
                    Log.Info($"refused {chosen.Name}: {chosen.Blocker.Detail}");
                    return Transition.Redraw;
                }

                // An OS/7 already on this disk gets NAMED before it is destroyed,
                // and destroying it takes a second, deliberate ENTER.
                //
                // This is where the upgrade path will attach (SETUP-PLAN §3,
                // screen 1's R=Repair, Phase 6): the question "install beside the
                // existing boot environment instead of over it" can only be asked
                // once Setup knows there IS one and which version it is. So the
                // probe is written now and the offer is not - an offer Setup
                // cannot honour would be worse than no offer.
                //
                // Deliberately NOT done during enumeration: the probe imports a
                // pool, and screen 4 lists every disk on the machine. Paying that
                // for the one disk somebody chose is seconds; paying it for all
                // of them, before anyone has chosen anything, is a screen that
                // takes a minute to appear.
                if (chosen.Os7Layout && _confirming != chosen.Name)
                {
                    _confirming = chosen.Name;
                    _existing = ExistingInstalls.Probe(chosen);
                    string found = _existing?.Describe() ?? "an OS/7 layout";
                    _note = $"{chosen.Name} already carries {found}. "
                            + "Press ENTER again to erase it.";
                    Log.Warn($"{chosen.Name} carries an existing install: {found}");
                    return Transition.Redraw;
                }

                _plan.Storage.Disk = chosen.StablePath;
                Log.Info($"target disk: {chosen.Name} ({chosen.StablePath}), {chosen.Size}"
                         + (_existing is not null ? $"; replacing {_existing.Describe()}" : ""));
                return Transition.To(new LayoutScreen(_plan, chosen));

            case Key.Enter:
                _note = "Setup found no disk it can install to.";
                return Transition.Redraw;

            case Key.Escape:
                return Transition.Back;

            default:
                if (!_list.Handle(key)) return Transition.Stay;
                // Moving the highlight retracts both the confirmation and the
                // note, so the screen never shows a finding about one disk while
                // a different one is selected.
                if (_disks.Count > 0 && _confirming is not null
                    && _confirming != _disks[_list.Selected].Name)
                {
                    _confirming = null;
                    _existing = null;
                    _note = null;
                }
                return Transition.Redraw;
        }
    }
}
