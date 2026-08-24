using System.Text;

namespace OS7.Spike.Look;

/// <summary>
/// Spike S1 — does the look actually work.
///
///     os7-s1 probe                 report geometry, TERM, and the decoder's own health
///     os7-s1 paint &lt;screen&gt;  paint one §3.1 mockup and exit
///     os7-s1 keys &lt;n&gt;        read n keypresses, log what each one decoded to
///
/// It writes the frame to stdout and everything else to stderr, so the harness
/// can point stdout at /dev/tty1 (where the screendump is taken) and still read
/// the evidence over the serial line. That split is the whole reason the program
/// can be driven from a headless VM at all.
/// </summary>
internal static class Program
{
    // The geometry to fall back to when there is no tty to ask. 80x25 is the
    // reference (§2.4) and being explicit about the fallback keeps a wrong
    // number from looking like a measurement.
    private const int FallbackCols = 80;
    private const int FallbackRows = 25;

    private static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        string cmd = args.Length > 0 ? args[0] : "probe";
        try
        {
            return cmd switch
            {
                "probe" => Probe(),
                "paint" => Paint(args.Length > 1 ? args[1] : "welcome"),
                "keys" => ReadKeys(args.Length > 1 ? int.Parse(args[1]) : 4),
                _ => Usage(),
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"S1-ERROR: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    private static int Usage()
    {
        Console.Error.WriteLine("usage: os7-s1 probe | paint <welcome|disk|layout|copying|testcard> | keys <n>");
        return 2;
    }

    private static (int cols, int rows) Geometry()
    {
        // stdout, because that is the thing being painted onto. Asking stdin
        // would measure the serial line when the harness redirects them apart.
        if (Termios.TryGetWindowSize(1, out int c, out int r))
            return (c, r);
        Console.Error.WriteLine("S1-GEOMETRY: TIOCGWINSZ failed, using the fallback");
        return (FallbackCols, FallbackRows);
    }

    private static int Probe()
    {
        (int cols, int rows) = Geometry();
        Console.Error.WriteLine($"S1-PROBE-TERM={Environment.GetEnvironmentVariable("TERM") ?? "(unset)"}");
        Console.Error.WriteLine($"S1-PROBE-GEOMETRY={cols}x{rows}");
        Console.Error.WriteLine($"S1-PROBE-BODY={Math.Min(80, cols)} left={(cols - Math.Min(80, cols)) / 2}");

        List<string> conflicts = Keys.PrefixConflicts();
        foreach (string c in conflicts)
            Console.Error.WriteLine($"S1-PROBE-KEYTABLE-CONFLICT: {c}");
        Console.Error.WriteLine($"S1-PROBE-KEYTABLE={(conflicts.Count == 0 ? "unambiguous" : "AMBIGUOUS")}");

        // Round-trip every glyph the UI draws through the encoder. This catches
        // a console that is not in UTF-8 mode before a screendump has to be
        // interpreted - the failure would otherwise look like a missing font.
        const string glyphs = "┌─┬┐├┼┤└┴┘│╔═╦╗╠╬╣╚╩╝║█▓▒░▀▄▌▐•ÄÖÜäöüß—€";
        byte[] enc = Encoding.UTF8.GetBytes(glyphs);
        string back = Encoding.UTF8.GetString(enc);
        Console.Error.WriteLine($"S1-PROBE-UTF8={(back == glyphs ? "ok" : "BROKEN")} "
                              + $"({glyphs.Length} glyphs, {enc.Length} bytes)");
        Console.Error.WriteLine("S1-PROBE-DONE");
        return 0;
    }

    private static int Paint(string which)
    {
        (int cols, int rows) = Geometry();
        Screen s = which switch
        {
            "welcome" => Screens.Welcome(cols, rows),
            "disk" => Screens.Disk(cols, rows, 0),
            "layout" => Screens.Layout(cols, rows),
            "copying" => Screens.Copying(cols, rows, 47),
            "testcard" => Screens.TestCard(cols, rows),
            _ => throw new ArgumentException($"unknown screen '{which}'"),
        };

        // Hide the cursor first: a block cursor sitting in the middle of a frame
        // is the difference between a screenshot and a screenshot with a defect
        // in it, and Setup never wants one on a display-only screen.
        using var stdout = Console.OpenStandardOutput();
        byte[] frame = Encoding.UTF8.GetBytes("\x1b[?25l" + s.Render());
        stdout.Write(frame, 0, frame.Length);
        stdout.Flush();

        Console.Error.WriteLine($"S1-PAINT={which} {cols}x{rows} {frame.Length}B");
        return 0;
    }

    private static int ReadKeys(int count)
    {
        // Raw mode on stdin. fd 0 is the tty the harness gives us; the frame
        // still goes to stdout, which may be a different tty.
        var saved = Termios.MakeRaw(0);
        try
        {
            int dropped = Termios.Drain(0);
            Console.Error.WriteLine($"S1-KEYS-DRAINED={dropped}");
            for (int i = 0; i < count; i++)
            {
                KeyPress? k = Keys.Read(() => Termios.ReadByte(0));
                if (k is null)
                {
                    Console.Error.WriteLine("S1-KEY-EOF");
                    break;
                }
                // One line per key, both halves on it: what arrived on the wire
                // and what the table made of it. A wrong table entry is only
                // visible when the two are printed together.
                Console.Error.WriteLine($"S1-KEY {i}: raw=[{k.Value.Raw}] -> {k.Value}");
            }
        }
        finally
        {
            Termios.Restore(0, saved);
        }
        Console.Error.WriteLine("S1-KEYS-DONE");
        return 0;
    }
}
