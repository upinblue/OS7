namespace OS7.Setup.Tui.Widgets;

/// <summary>
/// A boxed list with one highlighted row — Win2k's partition list and the
/// MS-DOS 6.22 settings box are the same widget with different contents.
///
/// The selection is black on light grey and spans the FULL inner width, which is
/// how the original drew it: a highlighted row, never a highlighted word.
///
/// It scrolls, because L10's mitigation for dropping Calamares is to read the
/// system's own lists — and /usr/share/zoneinfo has some six hundred entries,
/// where the Win2k screens it is modelled on never had more than a handful.
/// </summary>
internal sealed class SelectionList
{
    private readonly int _visible;

    public IReadOnlyList<string> Items { get; private set; }
    public int Selected { get; private set; }
    public int Top { get; private set; }

    public SelectionList(IReadOnlyList<string> items, int visibleRows, int selected = 0)
    {
        Items = items;
        _visible = Math.Max(1, visibleRows);
        Selected = Math.Clamp(selected, 0, Math.Max(0, items.Count - 1));
        ScrollIntoView();
    }

    public bool Handle(KeyPress key)
    {
        int before = Selected;
        switch (key.Key)
        {
            case Key.Up: Selected--; break;
            case Key.Down: Selected++; break;
            case Key.PageUp: Selected -= _visible; break;
            case Key.PageDown: Selected += _visible; break;
            case Key.Home: Selected = 0; break;
            case Key.End: Selected = Items.Count - 1; break;

            // Type-to-find. Not decoration: picking Europe/Berlin out of six
            // hundred zones with the arrow keys alone is a minute of holding
            // Down, and this is the one affordance the original screens never
            // needed because their lists were short.
            case Key.Char when char.IsLetterOrDigit(key.Rune):
                int from = JumpTo(key.Rune);
                if (from >= 0) Selected = from;
                break;

            default: return false;
        }
        Selected = Math.Clamp(Selected, 0, Math.Max(0, Items.Count - 1));
        ScrollIntoView();
        return Selected != before;
    }

    private int JumpTo(char c)
    {
        // Search after the current entry first, so repeated presses cycle
        // through the matches instead of sticking on the first one.
        for (int i = Selected + 1; i < Items.Count; i++)
            if (StartsWith(Items[i], c)) return i;
        for (int i = 0; i <= Selected && i < Items.Count; i++)
            if (StartsWith(Items[i], c)) return i;
        return -1;
    }

    private static bool StartsWith(string s, char c) =>
        s.Length > 0 && char.ToUpperInvariant(s[0]) == char.ToUpperInvariant(c);

    private void ScrollIntoView()
    {
        if (Selected < Top) Top = Selected;
        else if (Selected >= Top + _visible) Top = Selected - _visible + 1;
        Top = Math.Clamp(Top, 0, Math.Max(0, Items.Count - _visible));
    }

    /// <summary>
    /// How many columns a row's TEXT gets inside a box `width` wide: two borders
    /// and one column of padding on each side.
    ///
    /// Exposed because a caller that builds its rows in columns — screen 4 lays
    /// its disks out that way — has to size them to the room the box really has.
    /// DiskScreen passed a literal 66, which was this number for the box it drew
    /// and would have stopped being it the moment either end of the arithmetic
    /// moved. Nothing would have said so: `Draw` cuts an over-long row without
    /// complaining, so the only symptom is the right-hand end of a row quietly
    /// losing characters.
    /// </summary>
    public static int TextWidth(int boxWidth) => Math.Max(0, boxWidth - 4);

    /// <summary>Draw the box and its rows. `row`/`col` are the box's top left.</summary>
    public void Draw(Frame f, int row, int col, int width)
    {
        f.Box(row, col, width, _visible + 2);
        int inner = width - 2;
        int room = TextWidth(width);
        for (int i = 0; i < _visible; i++)
        {
            int index = Top + i;
            bool selected = index == Selected;
            int fg = selected ? Slot.Black : Slot.White;
            int bg = selected ? Slot.Grey : Slot.Field;
            f.Fill(row + 1 + i, col + 1, inner, ' ', fg, bg);
            if (index >= Items.Count) continue;
            string text = Items[index];
            if (text.Length > room) text = text[..room];
            f.Text(row + 1 + i, col + 2, text, fg, bg);
        }

        // A scroll hint, only when there is something off-screen.
        //
        // U+2191/U+2193 and NOT U+25B2/U+25BC. Fixedsys has no glyph for the
        // triangles at all - bdf2psf maps them onto something else through an
        // equivalence class, which is the same silent substitution that turned
        // the double-line box into a single-line one (BUILD-NOTES #26). The
        // arrows are real glyphs in the font, and drawing them here is why they
        // are in build/lib/psf.py's REQUIRED set rather than its WANTED one.
        if (Items.Count > _visible)
        {
            if (Top > 0) f.Put(row, col + width - 3, '↑', Slot.White, Slot.Field);
            if (Top + _visible < Items.Count)
                f.Put(row + _visible + 1, col + width - 3, '↓', Slot.White, Slot.Field);
        }
    }

    public int Height => _visible + 2;
}
