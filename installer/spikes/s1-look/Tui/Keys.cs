using System.Text;

namespace OS7.Spike.Look;

internal enum Key
{
    Unknown, Char, Enter, Escape, Tab, Backspace,
    Up, Down, Left, Right, Home, End, PageUp, PageDown, Insert, Delete,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

internal readonly record struct KeyPress(Key Key, char Rune, string Raw)
{
    public override string ToString() =>
        Key == Key.Char ? $"Char '{Rune}'" : Key.ToString();
}

/// <summary>
/// A hand-written escape-sequence decoder.
///
/// SETUP-PLAN §6.4 chooses this over .NET's terminfo layer, which "has known
/// gaps around F-keys under TERM=linux", and over Terminal.Gui. The claim is
/// that a table is enough because OS/7 targets exactly two terminal types. S1
/// tests it by pressing every key that matters on a real VT and comparing what
/// arrives against this table.
///
/// The Linux console is NOT vt100 about function keys, and that is the whole
/// reason this file exists:
///
///     F1-F5   ESC[[A .. ESC[[E     a Linux-only form; no other terminal emits it
///     F6-F12  ESC[17~ .. ESC[24~   the DEC/xterm form
///
/// The xterm forms (ESC OP for F1 and so on) are here too, because os7-setup
/// --serial (§7) will meet them on the far end of a serial line.
/// </summary>
internal static class Keys
{
    private static readonly Dictionary<string, Key> Sequences = new()
    {
        // Linux console function keys. F1-F5 only.
        ["\x1b[[A"] = Key.F1, ["\x1b[[B"] = Key.F2, ["\x1b[[C"] = Key.F3,
        ["\x1b[[D"] = Key.F4, ["\x1b[[E"] = Key.F5,

        // DEC/xterm function keys, used by the Linux console from F6 up and by
        // every serial client for the whole range.
        ["\x1b[11~"] = Key.F1, ["\x1b[12~"] = Key.F2, ["\x1b[13~"] = Key.F3,
        ["\x1b[14~"] = Key.F4, ["\x1b[15~"] = Key.F5, ["\x1b[17~"] = Key.F6,
        ["\x1b[18~"] = Key.F7, ["\x1b[19~"] = Key.F8, ["\x1b[20~"] = Key.F9,
        ["\x1b[21~"] = Key.F10, ["\x1b[23~"] = Key.F11, ["\x1b[24~"] = Key.F12,
        ["\x1bOP"] = Key.F1, ["\x1bOQ"] = Key.F2, ["\x1bOR"] = Key.F3, ["\x1bOS"] = Key.F4,

        // Arrows in both cursor modes. The Linux console sends the ESC[ form;
        // a client in application-cursor mode sends ESC O.
        ["\x1b[A"] = Key.Up, ["\x1b[B"] = Key.Down,
        ["\x1b[C"] = Key.Right, ["\x1b[D"] = Key.Left,
        ["\x1bOA"] = Key.Up, ["\x1bOB"] = Key.Down,
        ["\x1bOC"] = Key.Right, ["\x1bOD"] = Key.Left,

        // Navigation. The Linux console uses ESC[1~ / ESC[4~ for Home/End,
        // where xterm uses ESC[H / ESC[F - both are here.
        ["\x1b[1~"] = Key.Home, ["\x1b[4~"] = Key.End,
        ["\x1b[H"] = Key.Home, ["\x1b[F"] = Key.End,
        ["\x1bOH"] = Key.Home, ["\x1bOF"] = Key.End,
        ["\x1b[2~"] = Key.Insert, ["\x1b[3~"] = Key.Delete,
        ["\x1b[5~"] = Key.PageUp, ["\x1b[6~"] = Key.PageDown,
    };

    /// <summary>True while `s` could still grow into something in the table.</summary>
    internal static bool CouldContinue(string s)
    {
        foreach (string k in Sequences.Keys)
            if (k.Length > s.Length && k.StartsWith(s, StringComparison.Ordinal))
                return true;
        return false;
    }

    internal static KeyPress Decode(string s)
    {
        if (Sequences.TryGetValue(s, out Key k))
            return new KeyPress(k, '\0', Describe(s));
        if (s.Length == 1)
        {
            char c = s[0];
            return c switch
            {
                '\r' or '\n' => new KeyPress(Key.Enter, '\0', Describe(s)),
                '\t' => new KeyPress(Key.Tab, '\0', Describe(s)),
                '\x1b' => new KeyPress(Key.Escape, '\0', Describe(s)),
                '\x7f' or '\b' => new KeyPress(Key.Backspace, '\0', Describe(s)),
                _ => new KeyPress(Key.Char, c, Describe(s)),
            };
        }
        return new KeyPress(Key.Unknown, '\0', Describe(s));
    }

    /// <summary>Printable form of the raw bytes, for the evidence log.</summary>
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
    /// Read exactly one keypress from a raw-mode stream.
    ///
    /// One byte at a time; commit as soon as the accumulated string matches the
    /// table or can no longer grow into anything in it. No entry in the table is
    /// a proper prefix of another entry, so "matches" is unambiguous - CouldContinue
    /// is only ever consulted for strings that do NOT match.
    ///
    /// THE BARE ESCAPE KEY IS NOT HANDLED HERE, and pretending otherwise would be
    /// the bug. A lone ESC is the prefix of every sequence in the table, so this
    /// blocks on it until the next key arrives. Every terminal program has this
    /// problem and every one of them solves it with a timer: after ESC, switch to
    /// VMIN=0/VTIME=1 and treat "nothing followed within 100 ms" as Escape.
    /// os7-setup needs that (§3.1 screen 2 offers ESC), Phase 1 owes it, and S1
    /// does not exercise it - the harness presses arrows and F-keys, never ESC
    /// alone. Recorded so the omission is a decision rather than an oversight.
    /// </summary>
    internal static KeyPress? Read(Func<int> nextByte)
    {
        var sb = new StringBuilder();
        while (true)
        {
            int b = nextByte();
            if (b < 0) return sb.Length == 0 ? null : Decode(sb.ToString());
            sb.Append((char)b);
            string s = sb.ToString();
            if (Sequences.ContainsKey(s)) return Decode(s);
            if (!CouldContinue(s)) return Decode(s);
            if (sb.Length > 8) return Decode(s);   // nothing in the table is this long
        }
    }

    /// <summary>
    /// The property Read() depends on: no sequence is a proper prefix of another.
    /// Checked at startup rather than asserted in a comment, because the table is
    /// exactly the kind of thing that grows an ambiguous entry later.
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
