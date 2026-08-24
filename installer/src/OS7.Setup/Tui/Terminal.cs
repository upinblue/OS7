using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Text;
using OS7.Setup.Diagnostics;
using OS7.Setup.Native;

namespace OS7.Setup.Tui;

/// <summary>
/// The terminal Setup owns for its lifetime: raw mode, the palette, the font,
/// the frame buffer, and putting all of it back afterwards.
///
/// "Afterwards" includes crashing. A terminal left in raw mode with the cursor
/// hidden and a blue background is a machine whose console is unusable, on a box
/// that by definition has nothing else running on it — so Restore() is wired to
/// ProcessExit and to SIGINT/SIGTERM/SIGHUP as well as to the normal path, and
/// is safe to call twice.
/// </summary>
internal sealed class Terminal : IDisposable
{
    private const int StdIn = 0, StdOut = 1;

    private readonly FileStream _out;
    private readonly Termios.TermiosStruct _saved;
    private readonly List<PosixSignalRegistration> _signals = new();
    private Frame? _shown;
    private bool _restored;
    private Geometry? _geometry;
    private int _retakes;
    private long _lastRetakeTicks;

    public int Cols { get; private set; }
    public int Rows { get; private set; }
    public bool Resized { get; private set; }
    public Palette Palette { get; private set; } = Tui.Palette.Default;
    public Input Input { get; }

    /// <summary>
    /// The device Setup is painting on, e.g. "/dev/tty1", and whether it is a
    /// Linux virtual console. §2.7 forks the whole presentation on this: on a VT
    /// the palette IS the mechanism, and on a serial line neither the palette
    /// nor a console font exists at all.
    /// </summary>
    private static string? _device;
    private static bool _isVirtualConsole;

    private Terminal(int cols, int rows, Termios.TermiosStruct saved)
    {
        Cols = cols;
        Rows = rows;
        _saved = saved;
        _out = new FileStream(new SafeFileHandle((IntPtr)StdOut, ownsHandle: false),
                              FileAccess.Write);
        Input = new Input(StdIn);

        AppDomain.CurrentDomain.ProcessExit += (_, _) => Restore();
        foreach (PosixSignal sig in new[] { PosixSignal.SIGINT, PosixSignal.SIGTERM, PosixSignal.SIGHUP })
            _signals.Add(PosixSignalRegistration.Create(sig, ctx =>
            {
                Restore();
                ctx.Cancel = false;   // let the default action run; the console is safe now
            }));

        // SIGWINCH is a real case here, not a nicety: a serial client resizes,
        // and switching console font sizes changes the cell grid under a running
        // program. The flag is polled by the flow between keystrokes rather than
        // acted on inside the handler, because repainting from a signal handler
        // is how a frame ends up half-written.
        _signals.Add(PosixSignalRegistration.Create(PosixSignal.SIGWINCH, ctx =>
        {
            Resized = true;
            ctx.Cancel = true;
        }));
    }

    /// <summary>
    /// Take over the console: load the font, apply the palette, enter raw mode.
    ///
    /// Order matters. The font changes the cell grid, so it goes first and the
    /// geometry is read after it. The palette is applied before the first frame
    /// so that no frame is ever painted in Ubuntu's colours.
    /// </summary>
    public static Terminal Acquire(Geometry geometry)
    {
        _device = Native.Tty.Name(StdOut);
        _isVirtualConsole = Native.Tty.IsVirtualConsole(_device);
        Log.Info($"surface: {_device ?? "(not a tty)"} — "
                 + (_isVirtualConsole ? "Linux virtual console" : "not a virtual console"));

        LoadFont(geometry);
        ApplyPalette(Tui.Palette.Default);

        Termios.TermiosStruct saved = Termios.MakeRaw(StdIn);
        int dropped = Termios.Drain(StdIn);
        if (dropped > 0)
            Log.Info($"discarded {dropped} byte(s) queued before the first screen");

        var t = new Terminal(0, 0, saved);
        t._geometry = geometry;
        t.Measure(geometry, "start-up");
        t.Write("\x1b[?25l");        // hide the cursor: Setup never shows one
        return t;
    }

    /// <summary>
    /// Re-read the size, and say so only when it changed.
    ///
    /// Called before every frame, not only on SIGWINCH. An ioctl costs
    /// microseconds and a frame drawn to the wrong size costs the whole screen.
    /// </summary>
    public bool Measure(Geometry geometry, string why)
    {
        (int cols, int rows) = geometry.Measure(StdOut);
        Resized = false;
        if (cols == Cols && rows == Rows) return false;
        Log.Info($"terminal {cols}x{rows} ({why})");
        Cols = cols;
        Rows = rows;
        Invalidate();
        return true;
    }

    /// <summary>
    /// Take the console again after it has changed underneath us.
    ///
    /// THE CONSOLE IS NOT THE SAME OBJECT FOR THE WHOLE BOOT, and that is the
    /// finding this method exists for. Measured on 2026-08-24:
    ///
    ///   10:34:45  os7-setup starts. Console is the kernel's DUMMY device,
    ///             80x25, because fbcon has not taken over yet.
    ///   10:34:45  setfont fails: "Unable to load such font with such kernel
    ///             version" — KDFONTOP against a dummy console.
    ///   10:34:58  fbcon takes over. The console becomes 160x50, in fbcon's own
    ///             8x16 font, and everything Setup did to it is gone.
    ///
    /// systemd has no unit to order against for that — the takeover is a kernel
    /// event, and `After=systemd-udev-settle.service` does not cover it. So
    /// instead of trying to start late enough, Setup notices and re-takes: the
    /// font and the palette are re-applied whenever the size changes, which is
    /// self-healing for a mode change and for a serial client resizing too.
    ///
    /// It terminates because re-applying the font resizes the console at most
    /// once more, and the second pass finds nothing to change. The counter is
    /// there for the case that reasoning is wrong on some machine, not because
    /// it is expected to fire.
    /// </summary>
    /// <summary>Returns true when it actually did something.</summary>
    private bool Retake(string why)
    {
        if (!_isVirtualConsole || _geometry is null) return false;
        long now = Environment.TickCount64;
        if (_retakes > 0 && now - _lastRetakeTicks < RetakeIntervalMs) return false;
        if (_retakes >= MaxRetakes)
        {
            if (_retakes == MaxRetakes)
            {
                _retakes++;   // so this is said once, not on every tick
                Log.Warn($"the console is still not what it should be ({why}) after "
                         + $"{MaxRetakes} attempts; carrying on with what it is");
            }
            return false;
        }
        _retakes++;
        _lastRetakeTicks = now;
        Log.Info($"re-taking the console ({why}, attempt {_retakes})");
        LoadFont(_geometry);
        ApplyPalette(Palette);
        Invalidate();
        Measure(_geometry, "after re-taking the console");
        return true;
    }

    /// <summary>The grid the chosen font should produce on this framebuffer.</summary>
    private (int cols, int rows)? ExpectedGrid()
    {
        if (!_isVirtualConsole || _geometry is null) return null;
        int fw = _geometry.FramebufferWidth, fh = _geometry.FramebufferHeight;
        if (fw <= 0 || fh <= 0) return null;
        return Themes.PickFont(fw, fh).GridOn(fw, fh);
    }

    // Eight attempts, at most one a second. fbcon's takeover is the thing being
    // waited out and it happens once, seconds into the boot; a second between
    // tries is long enough not to fight it and eight is long enough to outlast
    // it. Both numbers are a bound on a race, not a tuning knob.
    private const int MaxRetakes = 8;
    private const int RetakeIntervalMs = 1000;

    /// <summary>Paint a frame, sending only the rows that changed.</summary>
    public void Show(Frame frame)
    {
        Write(frame.Render(_shown));
        _shown = frame;
    }

    /// <summary>Force the next Show to send everything.</summary>
    public void Invalidate() => _shown = null;

    /// <summary>
    /// Switch palettes — F5, the high-contrast mode from D5.
    ///
    /// The repaint is NOT optional and is not just tidiness. The framebuffer is
    /// truecolor, so every cell was resolved to RGB when it was written;
    /// changing the palette changes what LATER writes resolve to and leaves the
    /// screen exactly as it is. Measured by spike S1: after switching, the
    /// screen stayed on the old colour until it was redrawn.
    /// </summary>
    public void TogglePalette()
    {
        Palette = Palette == Tui.Palette.Default ? Tui.Palette.HighContrast : Tui.Palette.Default;
        ApplyPalette(Palette);
        Invalidate();
    }

    /// <summary>
    /// Called before every frame. Returns true when the frame must be redrawn.
    ///
    /// A size change is not just a redraw: on this platform it can mean the
    /// console Setup configured has been replaced by a different one (see
    /// Retake), so the font and the palette go back on before anything is
    /// painted into it.
    /// </summary>
    public bool Refresh()
    {
        bool changed = Measure(Geometry.Current, "resize");

        // The console is not only re-taken when it CHANGES, but whenever it is
        // not what the chosen font should have produced.
        //
        // `setfont` cannot be trusted to have worked. Measured 2026-08-24: while
        // fbcon was taking the console over, setfont exited 0 and the console
        // stayed in fbcon's own 8x16 font — the same command from a shell a
        // minute later worked. An exit code says a program ran, not that the
        // console changed, so the console is asked instead. Retake backs off on
        // its own, so this costs one comparison per tick once things settle.
        // A RETAKE ALWAYS MEANS REDRAW, whether or not the size moved.
        //
        // `setfont` clears the console. So a retake that loads the same font
        // again - which happens while fbcon's takeover is still settling -
        // wipes the screen without changing its size, and a Refresh that
        // answered "nothing changed" would leave it wiped: the frame Setup last
        // sent is still what it believes is on screen, so damage tracking finds
        // nothing to send. Measured 2026-08-24 as a Welcome screen with a status
        // bar and nothing above it.
        if (ExpectedGrid() is { } want && (Cols != want.cols || Rows != want.rows))
        {
            if (Retake($"console is {Cols}x{Rows}, expected {want.cols}x{want.rows}"))
                changed = true;
        }
        return changed;
    }

    private void Write(string s)
    {
        if (s.Length == 0) return;
        byte[] bytes = Encoding.UTF8.GetBytes(s);
        // One write(2) per frame. A frame emitted in pieces is a frame the
        // console paints in pieces, and over a serial line it is also a frame
        // that can interleave with whatever else is on the wire.
        _out.Write(bytes, 0, bytes.Length);
        _out.Flush();
    }

    public void Restore()
    {
        if (_restored) return;
        _restored = true;
        try
        {
            Write("\x1b[22;37;40m\x1b[2J\x1b[H\x1b[?25h");
            Termios.Restore(StdIn, _saved);
            if (Palette != Tui.Palette.Default) ApplyPalette(Tui.Palette.Default);
        }
        catch (Exception ex)
        {
            Log.Warn($"restoring the terminal failed: {ex.Message}");
        }
    }

    public void Dispose()
    {
        Restore();
        foreach (PosixSignalRegistration r in _signals) r.Dispose();
        _out.Dispose();
    }

    // -----------------------------------------------------------------------
    // The two things Setup does not implement itself.
    //
    // SETUP-PLAN §6.2 is explicit that the storage primitives are processes
    // rather than bindings; the same reasoning covers these. `setfont` and
    // `setvtrgb` are in `kbd`, which is in the base package list because the
    // installed system needs it anyway, and the palette files are the ones the
    // image already ships — so doing it here in C# would mean a second copy of a
    // decision (build/lib/palette.py) for no gain.
    // -----------------------------------------------------------------------
    private static void LoadFont(Geometry geometry)
    {
        if (!_isVirtualConsole)
        {
            // §2.7: there is no console font on a serial line. Skipped rather
            // than attempted, because `setfont` against a non-VT fails in a way
            // that reads like a broken image.
            Log.Info("not a virtual console — no console font");
            return;
        }
        string font = Themes.PickFont(geometry.FramebufferWidth,
                                      geometry.FramebufferHeight).Path;
        if (!File.Exists(font))
        {
            // Not fatal. The kernel's built-in TER16x32 is the closest match and
            // is what the boot entry asks for anyway (L20) - it has the box
            // glyphs, so Setup is usable, just not in its own font.
            Log.Warn($"console font {font} is missing; keeping the kernel's");
            return;
        }
        Run("setfont", "-C", _device!, font);
    }

    private static void ApplyPalette(Palette p)
    {
        if (!_isVirtualConsole)
        {
            // §2.7 again: the palette cannot be set over serial or SSH. The
            // fallback there is 24-bit SGR, which the renderer does not emit
            // yet - that is Phase 5, and it is a Surface, not a palette.
            Log.Info("not a virtual console — no palette");
            return;
        }
        string file = Themes.PaletteFile(p);
        if (!File.Exists(file))
        {
            Log.Warn($"palette {file} is missing; the console keeps Ubuntu's colours");
            return;
        }
        Run("setvtrgb", "-C", _device!, file);
    }

    private static void Run(string exe, params string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo(exe) { RedirectStandardError = true };
            foreach (string a in args) psi.ArgumentList.Add(a);
            using Process? p = Process.Start(psi);
            if (p is null) { Log.Warn($"{exe}: did not start"); return; }
            string err = p.StandardError.ReadToEnd();
            p.WaitForExit();
            if (p.ExitCode != 0)
                Log.Warn($"{exe} {string.Join(' ', args)} exited {p.ExitCode}: {err.Trim()}");
            else
                Log.Info($"{exe} {string.Join(' ', args)}");
        }
        catch (Exception ex)
        {
            Log.Warn($"{exe}: {ex.Message}");
        }
    }
}
