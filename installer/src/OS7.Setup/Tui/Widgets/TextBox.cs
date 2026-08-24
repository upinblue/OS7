using System.Text;

namespace OS7.Setup.Tui.Widgets;

/// <summary>
/// A one-line field. Masked when it holds a passphrase.
///
/// Masking is not decoration here: Setup runs on a console in a room, and the
/// disk passphrase is the one secret in the whole flow. It is also why the value
/// never reaches the log, the plan file or a screendump — see StoragePlan's
/// [JsonIgnore] for the other half of that.
/// </summary>
internal sealed class TextBox
{
    private readonly StringBuilder _text = new();

    public bool Masked { get; init; }
    public int MaxLength { get; init; } = 128;
    public string Value => _text.ToString();
    public int Length => _text.Length;

    public bool Handle(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Backspace when _text.Length > 0:
                _text.Length--;
                return true;

            // Printable only. A control character in a passphrase is a
            // passphrase that cannot be retyped at the boot prompt, where there
            // is no editing and no second chance.
            case Key.Char when !char.IsControl(key.Rune) && _text.Length < MaxLength:
                _text.Append(key.Rune);
                return true;

            default:
                return false;
        }
    }

    public void Clear() => _text.Clear();

    /// <summary>
    /// Draw the field. Shows a fixed-width run of blocks for a masked value, so
    /// the LENGTH is visible - which is what tells someone their keystrokes are
    /// arriving - without the content being.
    /// </summary>
    public void Draw(Frame f, int row, int col, int width, bool focused)
    {
        int fg = focused ? Slot.Black : Slot.White;
        int bg = focused ? Slot.Grey : Slot.Field;
        f.Fill(row, col, width, ' ', fg, bg);

        string shown = Masked ? new string('█', Math.Min(_text.Length, width - 2)) : Value;
        if (shown.Length > width - 2) shown = shown[^(width - 2)..];
        f.Text(row, col + 1, shown, fg, bg);

        if (focused)
        {
            // A visible caret, because the cursor itself is hidden for the whole
            // of Setup and a field with no caret looks like a label.
            int at = col + 1 + Math.Min(shown.Length, width - 3);
            f.Put(row, at, '_', fg, bg);
        }
    }
}
