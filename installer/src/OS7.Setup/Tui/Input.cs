using System.Text;
using OS7.Setup.Native;

namespace OS7.Setup.Tui;

internal enum Key
{
    /// <summary>Nothing arrived before the deadline. An idle tick, not an event.</summary>
    None,

    /// <summary>The terminal went away. Distinct from None on purpose — one of
    /// them means "the user is thinking" and the other means "there is nobody
    /// there", and treating them the same either spins or quits on a pause.</summary>
    Eof,

    Unknown, Char, Enter, Escape, Tab, Backspace,
    Up, Down, Left, Right, Home, End, PageUp, PageDown, Insert, Delete,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

internal readonly record struct KeyPress(Key Key, char Rune, string Raw)
{
    public static readonly KeyPress None = new(Key.None, '\0', "");

    /// <summary>Case-insensitive shortcut match, e.g. `R` on the Welcome screen.</summary>
    public bool Is(char c) =>
        Key == Key.Char && char.ToUpperInvariant(Rune) == char.ToUpperInvariant(c);

    public override string ToString() => Key == Key.Char ? $"'{Rune}'" : Key.ToString();
}

/// <summary>
/// A hand-written escape-sequence decoder.
///
/// SETUP-PLAN §6.4 chooses this over .NET's terminfo layer, which "has known
/// gaps around F-keys under TERM=linux", and the choice was measured rather than
/// argued: spike S1 pressed every key below on a real VT and recorded what
/// arrived. The Linux console splits its function keys across two encodings —
///
///     F1-F5   ESC[[A .. ESC[[E    a form no other terminal emits
///     F6-F12  ESC[17~ .. ESC[24~  the DEC/xterm form
///
/// — and F3=Quit and F5=Advanced are on the Linux-only side, which is exactly
/// where a terminfo layer with gaps would be wrong. The xterm forms are here too
/// because `os7-setup --serial` (§7) meets them on the far end of a line.
/// </summary>
internal sealed class Input
{
    // How long to wait for the rest of a sequence before calling a lone ESC the
    // Escape key. 100 ms is long enough for the remainder to arrive over a
    // 9600-baud serial line — an ESC[15~ is six bytes, about 6 ms — and short
    // enough that pressing Escape does not feel broken.
    private const int SequenceTimeoutMs = 100;

    // How long to sit idle before handing control back so the caller can look
    // around. 200 ms is imperceptible to a person and frequent enough that a
    // console replaced underneath Setup is repainted before anyone notices.
    private const int IdleTimeoutMs = 200;

    private static readonly Dictionary<string, Key> Sequences = new()
    {
        // Linux console function keys — F1 to F5 only.
        ["\x1b[[A"] = Key.F1, ["\x1b[[B"] = Key.F2, ["\x1b[[C"] = Key.F3,
        ["\x1b[[D"] = Key.F4, ["\x1b[[E"] = Key.F5,

        // DEC/xterm function keys: the Linux console from F6 up, and every
        // serial client for the whole range.
        ["\x1b[11~"] = Key.F1, ["\x1b[12~"] = Key.F2, ["\x1b[13~"] = Key.F3,
        ["\x1b[14~"] = Key.F4, ["\x1b[15~"] = Key.F5, ["\x1b[17~"] = Key.F6,
        ["\x1b[18~"] = Key.F7, ["\x1b[19~"] = Key.F8, ["\x1b[20~"] = Key.F9,
        ["\x1b[21~"] = Key.F10, ["\x1b[23~"] = Key.F11, ["\x1b[24~"] = Key.F12,
        ["\x1bOP"] = Key.F1, ["\x1bOQ"] = Key.F2, ["\x1bOR"] = Key.F3, ["\x1bOS"] = Key.F4,

        // Arrows in both cursor modes: the Linux console sends the ESC[ form, a
        // client in application-cursor mode sends ESC O.
        ["\x1b[A"] = Key.Up, ["\x1b[B"] = Key.Down,
        ["\x1b[C"] = Key.Right, ["\x1b[D"] = Key.Left,
        ["\x1bOA"] = Key.Up, ["\x1bOB"] = Key.Down,
        ["\x1bOC"] = Key.Right, ["\x1bOD"] = Key.Left,

        ["\x1b[1~"] = Key.Home, ["\x1b[4~"] = Key.End,
        ["\x1b[H"] = Key.Home, ["\x1b[F"] = Key.End,
        ["\x1bOH"] = Key.Home, ["\x1bOF"] = Key.End,
        ["\x1b[2~"] = Key.Insert, ["\x1b[3~"] = Key.Delete,
        ["\x1b[5~"] = Key.PageUp, ["\x1b[6~"] = Key.PageDown,
    };

    private readonly int _fd;

    public Input(int fd) => _fd = fd;

    /// <summary>
    /// Wait for one keypress, for at most `idleMs`.
    ///
    /// Returns Key.None when nothing arrived — an idle tick, so the caller can
    /// re-check the world and repaint. That is not politeness: fbcon can take
    /// the console over seconds into the boot and clear everything Setup drew,
    /// and a reader blocked in read(2) would leave the screen blank until
    /// somebody pressed a key (Terminal.Retake).
    ///
    /// One byte at a time; commit as soon as the accumulated string matches the
    /// table or can no longer grow into anything in it. No entry is a proper
    /// prefix of another (PrefixConflicts asserts it), so "matches" is
    /// unambiguous.
    ///
    /// A LONE ESC is the prefix of every sequence in the table, so once one
    /// arrives the deadline drops to SequenceTimeoutMs and "nothing followed" is
    /// the answer rather than a reason to keep waiting. Spike S1 named this as
    /// the debt Phase 1 owes; this is it being paid.
    /// </summary>
    public KeyPress Read(int idleMs = IdleTimeoutMs)
    {
        var sb = new StringBuilder(8);
        while (true)
        {
            Waited waited = Poll.Wait(_fd, sb.Length == 0 ? idleMs : SequenceTimeoutMs);
            if (waited == Waited.HangUp || waited == Waited.Error)
                return new KeyPress(Key.Eof, '\0', "");
            if (waited == Waited.Timeout)
                return sb.Length == 0 ? KeyPress.None : Decode(sb.ToString());

            int b = Termios.ReadByte(_fd);
            if (b < 0) return new KeyPress(Key.Eof, '\0', "");
            sb.Append((char)b);
            string s = sb.ToString();

            if (Sequences.ContainsKey(s)) return Decode(s);
            if (!CouldContinue(s)) return Decode(s);
            if (sb.Length > 8) return Decode(s);   // nothing in the table is this long
        }
    }

    private static bool CouldContinue(string s)
    {
        foreach (string k in Sequences.Keys)
            if (k.Length > s.Length && k.StartsWith(s, StringComparison.Ordinal))
                return true;
        return false;
    }

    internal static KeyPress Decode(string s)
    {
        if (Sequences.TryGetValue(s, out Key k)) return new KeyPress(k, '\0', Describe(s));
        if (s.Length == 1)
        {
            char c = s[0];
            return c switch
            {
                // CR, not LF. The Linux console sends CR for Enter, measured by
                // S1 and by docs/BUILD-NOTES.md #16 from the other direction.
                '\r' or '\n' => new KeyPress(Key.Enter, '\0', Describe(s)),
                '\t' => new KeyPress(Key.Tab, '\0', Describe(s)),
                '\x1b' => new KeyPress(Key.Escape, '\0', Describe(s)),
                '\x7f' or '\b' => new KeyPress(Key.Backspace, '\0', Describe(s)),
                _ => new KeyPress(Key.Char, c, Describe(s)),
            };
        }
        return new KeyPress(Key.Unknown, '\0', Describe(s));
    }

    /// <summary>Printable form of the raw bytes, for the log.</summary>
    internal static string Describe(string s)
    {
        var sb = new StringBuilder();
        foreach (char c in s)
        {
            if (c == '\x1b') sb.Append("ESC");
            else if (c == '\r') sb.Append("CR");
            else if (c == '\n') sb.Append("LF");
            else if (c == '\t') sb.Append("TAB");
            else if (c < 0x20 || c == 0x7f) sb.Append($"\\x{(int)c:x2}");
            else sb.Append(c);
        }
        return sb.ToString();
    }

    /// <summary>
    /// The property Read() depends on: no sequence is a proper prefix of another.
    /// Checked at start-up rather than asserted in a comment, because this table
    /// is exactly the kind of thing that grows an ambiguous entry later.
    /// </summary>
    internal static List<string> PrefixConflicts()
    {
        var bad = new List<string>();
        foreach (string a in Sequences.Keys)
            foreach (string b in Sequences.Keys)
                if (a.Length < b.Length && b.StartsWith(a, StringComparison.Ordinal))
                    bad.Add($"{Describe(a)} is a prefix of {Describe(b)}");
        return bad;
    }
}
