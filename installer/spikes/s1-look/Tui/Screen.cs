using System.Text;

namespace OS7.Spike.Look;

/// <summary>
/// The palette slots from SETUP-PLAN §2.1, named rather than numbered.
///
/// Only indices 0-7 are usable as backgrounds - the Linux console renders eight
/// background colours, not sixteen - which is why the two blues live in low
/// slots and index 6 ("cyan") is repurposed for the brand colour.
/// </summary>
internal static class Slot
{
    public const int Black = 0;         // #000000  status-bar and selection text
    public const int Field = 4;         // #0057ad  the field
    public const int Brand = 6;         // #1289ff  title stripe, progress fill
    public const int Grey = 7;          // #c0c0c0  status bar, selection bar
    public const int White = 15;        // #ffffff  body text, borders, title
}

internal readonly record struct Cell(char Rune, int Fg, int Bg)
{
    public static readonly Cell Blank = new(' ', Slot.White, Slot.Field);
}

/// <summary>
/// An 80xN cell buffer flushed as ONE write(2).
///
/// One write matters more than it looks: a frame emitted in pieces is a frame
/// the console paints in pieces, and over a serial line (§7, os7-setup --serial)
/// it is also a frame that can interleave with anything else on the wire.
///
/// No damage tracking here. os7-setup will want it (§6.4); a spike that repaints
/// four screens does not, and leaving it out keeps the thing being measured -
/// the escape sequences and the glyphs - visible in the code.
/// </summary>
internal sealed class Screen
{
    public int Cols { get; }
    public int Rows { get; }

    // Chrome is full-bleed and the body is capped at 80 columns and centred
    // (§2.4 layout rule). Left is where the body column starts.
    public int BodyWidth => Math.Min(80, Cols);
    public int Left => (Cols - BodyWidth) / 2;

    private readonly Cell[,] _cells;

    public Screen(int cols, int rows)
    {
        Cols = cols;
        Rows = rows;
        _cells = new Cell[rows, cols];
        Clear();
    }

    public void Clear()
    {
        for (int r = 0; r < Rows; r++)
            for (int c = 0; c < Cols; c++)
                _cells[r, c] = Cell.Blank;
    }

    public void Put(int row, int col, char rune, int fg, int bg)
    {
        if (row < 0 || row >= Rows || col < 0 || col >= Cols) return;
        _cells[row, col] = new Cell(rune, fg, bg);
    }

    public void Text(int row, int col, string s, int fg = Slot.White, int bg = Slot.Field)
    {
        for (int i = 0; i < s.Length; i++)
            Put(row, col + i, s[i], fg, bg);
    }

    /// <summary>Body-relative text: column 0 is the left edge of the 80-cell column.</summary>
    public void Body(int row, int col, string s, int fg = Slot.White, int bg = Slot.Field)
        => Text(row, Left + col, s, fg, bg);

    public void Fill(int row, int col, int width, char rune, int fg, int bg)
    {
        for (int i = 0; i < width; i++)
            Put(row, col + i, rune, fg, bg);
    }

    /// <summary>
    /// Title row and the brand stripe under it, both full-bleed (§2.4).
    ///
    /// The stripe is SPACES ON THE BRAND BACKGROUND, not a row of '═'. §3.1 is
    /// explicit about this and it is the difference between a solid bar and a
    /// row of double rules with gaps between them - the glyph occupies rows 6-8
    /// of a 16-row cell, so drawn as characters the "stripe" would be mostly
    /// field colour.
    /// </summary>
    public void Chrome(string title, string status)
    {
        Fill(0, 0, Cols, ' ', Slot.White, Slot.Field);
        Text(0, 1, title, Slot.White, Slot.Field);
        Fill(1, 0, Cols, ' ', Slot.White, Slot.Brand);
        Fill(Rows - 1, 0, Cols, ' ', Slot.Black, Slot.Grey);
        Text(Rows - 1, 1, status, Slot.Black, Slot.Grey);
    }

    public void Box(int row, int col, int width, int height)
    {
        Put(row, col, '┌', Slot.White, Slot.Field);
        Put(row, col + width - 1, '┐', Slot.White, Slot.Field);
        Put(row + height - 1, col, '└', Slot.White, Slot.Field);
        Put(row + height - 1, col + width - 1, '┘', Slot.White, Slot.Field);
        for (int i = 1; i < width - 1; i++)
        {
            Put(row, col + i, '─', Slot.White, Slot.Field);
            Put(row + height - 1, col + i, '─', Slot.White, Slot.Field);
        }
        for (int i = 1; i < height - 1; i++)
        {
            Put(row + i, col, '│', Slot.White, Slot.Field);
            Put(row + i, col + width - 1, '│', Slot.White, Slot.Field);
        }
    }

    public void BoxDivider(int row, int col, int width)
    {
        Put(row, col, '├', Slot.White, Slot.Field);
        Put(row, col + width - 1, '┤', Slot.White, Slot.Field);
        for (int i = 1; i < width - 1; i++)
            Put(row, col + i, '─', Slot.White, Slot.Field);
    }

    /// <summary>
    /// Serialise to one string of SGR + text.
    ///
    /// The VT is told the colour by PALETTE INDEX, never by 24-bit SGR: §2.7
    /// records that fbcon accepts a truecolor sequence and then snaps it to the
    /// nearest of its sixteen entries, so emitting RGB here would silently undo
    /// the whole mechanism.
    ///
    /// INTENSITY IS SET EXPLICITLY ON EVERY CHANGE, and that is not belt and
    /// braces. On the Linux console the bright-foreground sequences ESC[90m to
    /// ESC[97m are "colour n-90 AND bold", and the bold half is STICKY: a later
    /// ESC[36m sets colour 6 and inherits the bold, which the console renders as
    /// entry 6+8 = 14. Measured on the S1 progress bar, which asked for the
    /// brand blue #1289ff (entry 6) after a run of white text and got #55ffff
    /// (entry 14). So: ESC[1;3xm for 8-15, ESC[22;3xm for 0-7, always.
    ///
    /// Background is always ESC[4xm - there is no background above 7 to emit
    /// (the console renders eight of them) and Slot keeps every background-
    /// capable colour below 8 for exactly that reason.
    /// </summary>
    public string Render()
    {
        var sb = new StringBuilder(Rows * Cols * 2);
        sb.Append("\x1b[H");                 // home, without clearing: the frame covers everything
        int fg = -1, bg = -1;
        for (int r = 0; r < Rows; r++)
        {
            if (r > 0) sb.Append("\x1b[").Append(r + 1).Append(";1H");
            for (int c = 0; c < Cols; c++)
            {
                Cell cell = _cells[r, c];
                if (cell.Fg != fg || cell.Bg != bg)
                {
                    fg = cell.Fg;
                    bg = cell.Bg;
                    sb.Append("\x1b[");
                    sb.Append(fg < 8 ? 22 : 1);   // normal or bold, never inherited
                    sb.Append(';');
                    sb.Append(30 + (fg & 7));
                    sb.Append(';');
                    sb.Append(40 + bg);           // bg is always 0-7 by construction
                    sb.Append('m');
                }
                sb.Append(cell.Rune);
            }
        }
        return sb.ToString();
    }
}
