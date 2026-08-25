using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 2 — the licence. SETUP-PLAN §3, modelled on the Win2k EULA screen:
/// F8 to accept, ESC to decline, PGDN to read on.
///
/// The text is read from disk, not compiled in, and it stays that way now that
/// the licence question is settled. The reason it was written this way was that
/// open question 5 was open and baking a licence into the binary would have
/// settled it by accident; the reason it survives its own answer is the better
/// one: the licence a user agrees to has to be the file the image ACTUALLY
/// ships. A compiled-in copy can disagree with /usr/share/os7/LICENSE and
/// nothing would say so. (Q5 resolved 2026-08-25 — MIT, ../../docs/DECISIONS.md.)
/// </summary>
internal sealed class LicenceScreen : Screen
{
    internal const string Path = "/usr/share/os7/LICENSE";

    private readonly InstallPlan _plan;
    private readonly string[] _lines;
    private readonly bool _readable;
    private int _top;
    private int _visible = 14;

    public LicenceScreen(InstallPlan plan)
    {
        _plan = plan;
        _lines = ReadLicence(out _readable);
    }

    public override string Status =>
        !_readable ? "ESC=Quit"
        : AtEnd ? "F8=I agree   ESC=I do not agree   PGUP=Back"
                : "F8=I agree   ESC=I do not agree   PGDN=Next page";

    private bool AtEnd => _top + _visible >= _lines.Length;

    public override void Layout(int cols, int rows)
    {
        // Body rows: 0 and 1 are chrome, the last is the status bar. Leave three
        // for the heading and two for the "page x of y" line under the box.
        _visible = Math.Max(4, rows - 9);
        Clamp();
    }

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "OS/7 Licence Agreement");

        int left = f.Left + 5;
        int width = f.BoxWidth;
        f.Box(4, left, width, _visible + 2);
        for (int i = 0; i < _visible; i++)
        {
            int index = _top + i;
            if (index >= _lines.Length) break;
            string text = _lines[index];
            if (text.Length > width - 4) text = text[..(width - 4)];
            f.Text(5 + i, left + 2, text);
        }

        // The last page is a special case and not a rounding one. Scrolling
        // clamps `_top` to Length - _visible, which is not a multiple of
        // _visible, so the arithmetic below reports page 1 for a document whose
        // last page starts five lines in. Naming the end explicitly is the only
        // way the number means anything at the one place a reader checks it.
        int pages = _visible <= 0 ? 1 : Math.Max(1, (_lines.Length + _visible - 1) / _visible);
        int page = AtEnd ? pages : Math.Min(pages, _top / Math.Max(1, _visible) + 1);
        f.Text(6 + _visible, left, $"Page {page} of {pages}", Slot.Brand);
        if (AtEnd)
            f.Text(6 + _visible, left + 20,
                   "To accept the agreement, press F8.", Slot.White);
    }

    public override Transition Handle(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.F8 when _readable:
                Log.Info("licence accepted");
                return Transition.To(new RegionalScreen(_plan));

            // Refused rather than ignored. The text below says Setup will not
            // install until it can show the licence, and a key that silently
            // does nothing would make that sentence untrue.
            case Key.F8:
                Log.Error("F8 refused: the licence text was not readable");
                return Transition.Stay;

            case Key.Escape:
                // Declining is a quit, not a step back. Win2k did the same, and
                // it is the one place where ESC is not "go back one screen".
                Log.Info("licence declined — quitting");
                return Transition.Quit;

            case Key.PageDown or Key.Down:
                _top += key.Key == Key.Down ? 1 : _visible;
                Clamp();
                return Transition.Redraw;

            case Key.PageUp or Key.Up:
                _top -= key.Key == Key.Up ? 1 : _visible;
                Clamp();
                return Transition.Redraw;

            case Key.Home:
                _top = 0;
                return Transition.Redraw;

            case Key.End:
                _top = int.MaxValue;
                Clamp();
                return Transition.Redraw;

            default:
                return Transition.Stay;
        }
    }

    private void Clamp() => _top = Math.Clamp(_top, 0, Math.Max(0, _lines.Length - _visible));

    private static string[] ReadLicence(out bool readable)
    {
        readable = false;
        try
        {
            if (File.Exists(Path))
            {
                string[] lines = File.ReadAllLines(Path);
                if (lines.Length > 0)
                {
                    readable = true;
                    return lines;
                }
                Log.Warn($"{Path} is empty");
            }
            else
            {
                Log.Warn($"{Path} is missing");
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"reading {Path} failed: {ex.Message}");
        }
        // Says what is wrong instead of showing an empty box. A licence screen
        // with nothing on it is the one screen where "it looked fine" would be
        // the worst possible outcome.
        return new[]
        {
            "The licence text could not be read from this medium.",
            "",
            $"Expected it at: {Path}",
            "",
            "This is a defect in the OS/7 image, not in your computer.",
            "Setup will not install OS/7 until it can show you the licence.",
        };
    }
}
