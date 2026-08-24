using System.Text;

namespace OS7.Setup.Tui;

internal readonly record struct Cell(char Rune, int Fg, int Bg)
{
    public static readonly Cell Blank = new(' ', Slot.White, Slot.Field);
}

/// <summary>
/// A grid of cells, and the drawing primitives every screen is built from.
///
/// Chrome is FULL-BLEED and body content is capped at 80 columns and centred —
/// §2.4's layout rule, which exists because UEFI hands out whatever GOP mode the
/// firmware likes and 200-character paragraphs are not a design. `Body` is the
/// body-relative writer; `Text` is absolute and is for chrome.
/// </summary>
internal sealed class Frame
{
    public int Cols { get; }
    public int Rows { get; }

    public int BodyWidth => BodyWidthFor(Cols);
    public int Left => (Cols - BodyWidth) / 2;

    /// <summary>
    /// The §2.4 cap, as a function of a console width rather than of a frame.
    ///
    /// A screen that has to size a widget before there is a frame to measure —
    /// Screen.Layout is handed raw terminal columns — must get the same answer
    /// as the frame it will later be drawn into. Two copies of `Math.Min(80, …)`
    /// is one copy too many for a number that decides where every box on every
    /// screen ends.
    /// </summary>
    public static int BodyWidthFor(int cols) => Math.Min(80, Math.Max(1, cols));

    private readonly Cell[] _cells;

    public Frame(int cols, int rows)
    {
        Cols = Math.Max(1, cols);
        Rows = Math.Max(1, rows);
        _cells = new Cell[Cols * Rows];
        Clear();
    }

    public Cell this[int row, int col] => _cells[row * Cols + col];

    public void Clear()
    {
        for (int i = 0; i < _cells.Length; i++) _cells[i] = Cell.Blank;
    }

    public void Put(int row, int col, char rune, int fg, int bg)
    {
        if ((uint)row >= (uint)Rows || (uint)col >= (uint)Cols) return;
        _cells[row * Cols + col] = new Cell(rune, fg, bg);
    }

    public void Text(int row, int col, string s, int fg = Slot.White, int bg = Slot.Field)
    {
        for (int i = 0; i < s.Length; i++) Put(row, col + i, s[i], fg, bg);
    }

    public void Body(int row, int col, string s, int fg = Slot.White, int bg = Slot.Field)
        => Text(row, Left + col, s, fg, bg);

    public void Fill(int row, int col, int width, char rune, int fg, int bg)
    {
        for (int i = 0; i < width; i++) Put(row, col + i, rune, fg, bg);
    }

    /// <summary>
    /// The title row, the brand stripe under it and the status bar. Every screen
    /// has all three, and all three touch the screen edges (§2.4).
    ///
    /// THE STRIPE IS SPACES ON THE BRAND BACKGROUND, not a row of '═'. §3.1 says
    /// so and it is not a stylistic preference: the double-rule glyph occupies
    /// three rows of a sixteen-row cell, so drawn as characters the "stripe"
    /// would be mostly field colour with two thin lines in it.
    ///
    /// <paramref name="right"/> is the release, right-aligned on the title row.
    /// It is chrome and not a screen's business for the same reason the title is
    /// — it must be identical everywhere, and the one question every support
    /// call opens with is which version this is. Whichever screen a photograph
    /// was taken of, the answer is in it.
    /// </summary>
    public void Chrome(string title, string status, string? right = null)
    {
        Fill(0, 0, Cols, ' ', Slot.White, Slot.Field);
        Text(0, 1, title, Slot.White, Slot.Field);

        // Dropped rather than truncated or wrapped when it will not fit. UEFI
        // hands out whatever GOP mode the firmware likes (§2.4) and a narrow
        // console is a real case; a half-printed version number is worse than
        // none, because it still reads as a version number. Two columns of gap,
        // so the two never touch and look like one string.
        if (!string.IsNullOrEmpty(right))
        {
            int col = Cols - 1 - right.Length;
            if (col >= 1 + title.Length + 2)
                Text(0, col, right, Slot.White, Slot.Field);
        }

        Fill(1, 0, Cols, ' ', Slot.White, Slot.Brand);
        Fill(Rows - 1, 0, Cols, ' ', Slot.Black, Slot.Grey);
        Text(Rows - 1, 1, status, Slot.Black, Slot.Grey);
    }

    public void Box(int row, int col, int width, int height,
                    int fg = Slot.White, int bg = Slot.Field)
    {
        if (width < 2 || height < 2) return;
        Put(row, col, '┌', fg, bg);
        Put(row, col + width - 1, '┐', fg, bg);
        Put(row + height - 1, col, '└', fg, bg);
        Put(row + height - 1, col + width - 1, '┘', fg, bg);
        for (int i = 1; i < width - 1; i++)
        {
            Put(row, col + i, '─', fg, bg);
            Put(row + height - 1, col + i, '─', fg, bg);
        }
        for (int i = 1; i < height - 1; i++)
        {
            Put(row + i, col, '│', fg, bg);
            Put(row + i, col + width - 1, '│', fg, bg);
        }
    }

    public void Divider(int row, int col, int width, int fg = Slot.White, int bg = Slot.Field)
    {
        Put(row, col, '├', fg, bg);
        Put(row, col + width - 1, '┤', fg, bg);
        for (int i = 1; i < width - 1; i++) Put(row, col + i, '─', fg, bg);
    }

    /// <summary>
    /// Serialise the whole frame, or only the rows that differ from `previous`.
    ///
    /// COLOURS GO OUT AS PALETTE INDICES, never as 24-bit SGR. §2.7 records that
    /// fbcon accepts a truecolor sequence and then snaps it to the nearest of its
    /// sixteen entries, so emitting RGB on the VT would silently undo the entire
    /// palette mechanism. The serial surface is the other way round and is
    /// Phase 5; `Surface` is where that fork goes.
    ///
    /// INTENSITY IS EMITTED ON EVERY COLOUR CHANGE. On the Linux console
    /// ESC[90m-ESC[97m mean "colour n-90 AND bold", and the bold half is sticky:
    /// a later ESC[36m sets colour 6, inherits the bold and renders entry 6+8.
    /// Spike S1 hit exactly that on the progress bar, which is the only element
    /// in §3.1 where the brand blue is a foreground. docs/BUILD-NOTES.md #30.
    /// </summary>
    public string Render(Frame? previous = null)
    {
        var sb = new StringBuilder(Rows * Cols * 2);
        int fg = -1, bg = -1;
        for (int r = 0; r < Rows; r++)
        {
            if (previous is not null && previous.Cols == Cols && RowEquals(previous, r)) continue;
            sb.Append("\x1b[").Append(r + 1).Append(";1H");
            for (int c = 0; c < Cols; c++)
            {
                Cell cell = _cells[r * Cols + c];
                if (cell.Fg != fg || cell.Bg != bg)
                {
                    fg = cell.Fg;
                    bg = cell.Bg;
                    sb.Append("\x1b[")
                      .Append(fg < 8 ? 22 : 1)      // normal or bold, never inherited
                      .Append(';').Append(30 + (fg & 7))
                      .Append(';').Append(40 + (bg & 7))
                      .Append('m');
                }
                sb.Append(cell.Rune);
            }
        }
        return sb.ToString();
    }

    private bool RowEquals(Frame other, int row)
    {
        int b = row * Cols;
        for (int c = 0; c < Cols; c++)
            if (!_cells[b + c].Equals(other._cells[b + c])) return false;
        return true;
    }
}
