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

    public DiskScreen(InstallPlan plan)
    {
        _plan = plan;
        _disks = Disks.Enumerate();
        _visible = 10;
        // Start on the plan's disk when there is one - an --unattend plan
        // replayed interactively, or a step back from screen 5.
        _list = Build(_visible, Math.Max(0, _disks.FindIndex(d => d.StablePath == _plan.Storage.Disk)));
    }

    private int _visible;

    private SelectionList Build(int rows, int selected)
    {
        var labels = new List<string>();
        foreach (Disk d in _disks) labels.Add(d.Describe(66));
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
        if (visible == _visible) return;
        _visible = visible;
        _list = Build(visible, _list.Selected);
    }

    public override string Status => "ENTER=Select   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Setup will install OS/7 on the disk selected below.");
        f.Body(5, 5, "Use the UP and DOWN ARROW keys to select a disk, then press ENTER.");

        int left = f.Left + 5;
        int width = Math.Min(70, f.BodyWidth - 10);
        _list.Draw(f, 7, left, width);

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
                    _note = $"{chosen.Name} cannot be used: {chosen.Blocker}.";
                    Log.Info($"refused {chosen.Name}: {chosen.Blocker}");
                    return Transition.Redraw;
                }
                _plan.Storage.Disk = chosen.StablePath;
                Log.Info($"target disk: {chosen.Name} ({chosen.StablePath}), {chosen.Size}");
                return Transition.To(new LayoutScreen(_plan, chosen));

            case Key.Enter:
                _note = "Setup found no disk it can install to.";
                return Transition.Redraw;

            case Key.Escape:
                return Transition.Back;

            default:
                return _list.Handle(key) ? Transition.Redraw : Transition.Stay;
        }
    }
}
