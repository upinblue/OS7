using OS7.Setup.Diagnostics;
using OS7.Setup.Native;

namespace OS7.Setup.Tui;

/// <summary>
/// How big the canvas is, and whether it was forced.
///
/// §2.4: 80x25 is not obtainable everywhere — UEFI hands out whatever GOP mode
/// the firmware likes — so the layout rule is full-bleed chrome with the body
/// capped at 80 and centred, and `os7.setup.geometry=80x25` forces a
/// letterboxed exact canvas for screenshots and marketing.
///
/// Spike S1 measured the reference case: 1280x800 with the 16x32 font gives
/// exactly 80x25, and TIOCGWINSZ agrees with the kernel about it.
/// </summary>
internal sealed class Geometry
{
    // What to fall back to when there is no tty to ask. Stated as a constant so
    // that a wrong number never looks like a measurement.
    private const int FallbackCols = 80, FallbackRows = 25;

    public static Geometry Current { get; private set; } = new(null, (0, 0));

    private readonly (int cols, int rows)? _forced;

    public int FramebufferWidth { get; }
    public int FramebufferHeight { get; }

    private Geometry((int, int)? forced, (int w, int h) fb)
    {
        _forced = forced;
        FramebufferWidth = fb.w;
        FramebufferHeight = fb.h;
    }

    /// <summary>Read `os7.setup.geometry=` off the kernel command line.</summary>
    public static Geometry FromCommandLine(string? overrideSpec = null)
    {
        string? spec = overrideSpec ?? Kernel.Parameter("os7.setup.geometry");
        (int, int)? forced = null;
        if (spec is not null)
        {
            if (TryParse(spec, out int c, out int r)) forced = (c, r);
            else Log.Warn($"os7.setup.geometry={spec} is not <cols>x<rows>; ignoring it");
        }
        var g = new Geometry(forced, FramebufferSizeFromSysfs());
        Current = g;
        return g;
    }

    private static bool TryParse(string spec, out int cols, out int rows)
    {
        cols = rows = 0;
        string[] parts = spec.Split('x');
        return parts.Length == 2
               && int.TryParse(parts[0], out cols) && int.TryParse(parts[1], out rows)
               && cols > 0 && rows > 0;
    }

    public (int cols, int rows) Measure(int fd)
    {
        if (_forced is { } f) return f;
        if (Ioctl.TryGetWindowSize(fd, out int c, out int r)) return (c, r);
        Log.Warn($"TIOCGWINSZ failed; assuming {FallbackCols}x{FallbackRows}");
        return (FallbackCols, FallbackRows);
    }

    /// <summary>
    /// The framebuffer's size in PIXELS, which is what decides the font — not
    /// the cell count, because the cell count is what the font decides.
    /// (0, 0) when there is no framebuffer at all, i.e. on a serial console.
    /// </summary>
    private static (int, int) FramebufferSizeFromSysfs()
    {
        try
        {
            string path = "/sys/class/graphics/fb0/virtual_size";
            if (!File.Exists(path)) return (0, 0);
            string[] wh = File.ReadAllText(path).Trim().Split(',');
            if (wh.Length == 2 && int.TryParse(wh[0], out int w) && int.TryParse(wh[1], out int h))
                return (w, h);
            Log.Warn($"{path} reads '{string.Join(",", wh)}', which is not <w>,<h>");
            return (0, 0);
        }
        catch (Exception ex)
        {
            Log.Warn($"reading the framebuffer size failed: {ex.Message}");
            return (0, 0);
        }
    }
}

internal static class Kernel
{
    private static string? _cmdline;

    /// <summary>`name=value` off /proc/cmdline, or null. Empty for a bare flag.</summary>
    public static string? Parameter(string name)
    {
        _cmdline ??= SafeRead("/proc/cmdline");
        foreach (string tok in _cmdline.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (tok == name) return "";
            if (tok.StartsWith(name + "=", StringComparison.Ordinal))
                return tok[(name.Length + 1)..];
        }
        return null;
    }

    public static bool Flag(string name) => Parameter(name) is not null;

    private static string SafeRead(string path)
    {
        try { return File.ReadAllText(path); }
        catch { return ""; }
    }
}
