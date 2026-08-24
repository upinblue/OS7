namespace OS7.Setup.Tui;

/// <summary>
/// The palette slots from SETUP-PLAN §2.1, named rather than numbered.
///
/// Only indices 0-7 can be a BACKGROUND — the Linux console renders eight
/// background colours, not sixteen — which is why both OS/7 blues live in low
/// slots and index 6 ("cyan") is repurposed for the brand colour. Keep every
/// background-capable colour below 8 or the renderer has nothing to emit.
///
/// The RGB values behind these live in build/lib/palette.py, which generates the
/// .vtrgb files the image ships. Spike S1 measured all of them exact on a
/// framebuffer.
/// </summary>
internal static class Slot
{
    public const int Black = 0;    // #000000  text on the status bar and on selections
    public const int Field = 4;    // #0057ad  the field. 7.08:1 against white, AAA
    public const int Brand = 6;    // #1289ff  title stripe, progress fill, accents
    public const int Grey = 7;     // #c0c0c0  status bar, selection bar
    public const int White = 15;   // #ffffff  body text, box borders, title
}

/// <summary>
/// Which palette the console is showing, and how to change it.
///
/// NOT set on the kernel command line. Spike S1 measured `setvtrgb.service` —
/// shipped enabled by Ubuntu — replacing the whole palette from /etc/vtrgb at
/// ~11.8 s, before fbcon takes the console over at ~14.0 s. There is no window
/// in which a command-line palette is ever displayed and no error is reported
/// anywhere. docs/BUILD-NOTES.md #25.
/// </summary>
internal enum Palette
{
    Default,        // #0057ad field
    HighContrast,   // #003366 field, toggled with F5
}

internal static class Themes
{
    internal const string PaletteDir = "/usr/share/os7";
    internal const string FontDir = "/usr/share/consolefonts";

    internal static string PaletteFile(Palette p) => p switch
    {
        Palette.HighContrast => $"{PaletteDir}/palette-contrast.vtrgb",
        _ => $"{PaletteDir}/palette-default.vtrgb",
    };

    // The reference grid: SETUP-PLAN §2.4 draws every mockup at 80x25, and the
    // layout rule (full-bleed chrome, body capped at 80 and centred) is written
    // for it. Anything smaller is a screen the mockups do not fit on.
    internal const int RefCols = 80, RefRows = 25;

    /// <summary>
    /// The biggest font that still gives an 80x25 grid on this framebuffer.
    ///
    /// §2.4: "Setup picks by framebuffer height", and 8x16 is "unreadable on a
    /// modern panel — at 1920x1080 it gives a 240x67 grid". So the rule is not a
    /// height threshold pulled out of the air, it is arithmetic: 16x32 needs
    /// 80*16 = 1280 across and 25*32 = 800 down, which is exactly the reference
    /// geometry §2.4 names and exactly what spike S1 measured.
    ///
    /// Getting this wrong is not subtle and is not loud either: the first run of
    /// os7-setup used a 900px threshold, so a 1280x800 console picked 8x16, and
    /// Setup drew a perfectly correct 80x25 screen into the top-left quarter of
    /// the framebuffer.
    /// </summary>
    internal static ConsoleFont PickFont(int fbWidth, int fbHeight) =>
        (fbWidth >= RefCols * 16 && fbHeight >= RefRows * 32)
            ? new ConsoleFont($"{FontDir}/os7-fixedsys-16x32.psf.gz", 16, 32)
            : new ConsoleFont($"{FontDir}/os7-fixedsys-8x16.psf.gz", 8, 16);
}

/// <summary>
/// A console font, and the cell it draws in.
///
/// The cell size is carried alongside the path because Setup has to be able to
/// say what grid it EXPECTS — `setfont` can return 0 and change nothing, so
/// "did the font load" is a question about the console's geometry afterwards
/// and not about an exit code. See Terminal.Retake.
/// </summary>
internal readonly record struct ConsoleFont(string Path, int CellWidth, int CellHeight)
{
    public (int cols, int rows) GridOn(int fbWidth, int fbHeight) =>
        (fbWidth / CellWidth, fbHeight / CellHeight);
}
