using OS7.Setup.Diagnostics;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen E — Setup cannot continue. SETUP-PLAN §3.1.
///
/// "Errors get a screen, never a scrolled stack trace. Every error screen names
/// the command that failed and its output." That is the contract, and it is why
/// this takes the command and its output as fields rather than a formatted
/// string: an error that cannot say what it ran is an error nobody can act on.
///
/// F2 writes the log somewhere else, which is the one thing a person on a
/// machine with no installed OS can actually do with it.
/// </summary>
internal sealed class ErrorScreen : Screen
{
    private readonly string _summary;
    private readonly string[] _detail;
    private readonly string? _command;
    private readonly bool _fatal;
    private string? _exportNote;

    private ErrorScreen(string summary, string[] detail, string? command, bool fatal)
    {
        _summary = summary;
        _detail = detail;
        _command = command;
        _fatal = fatal;
        Log.Error(summary + (command is null ? "" : $" (running: {command})"));
        foreach (string d in detail) Log.Error("  " + d);
    }

    /// <summary>A command Setup ran came back wrong. The common case.</summary>
    public static ErrorScreen ForCommand(string summary, string command, string output) =>
        new(summary, output.ReplaceLineEndings("\n").Split('\n'), command, fatal: true);

    /// <summary>An exception nothing else caught. Rare, and it must still land here.</summary>
    public static ErrorScreen ForException(Exception ex) =>
        new("Setup encountered an unexpected error.",
            new[] { $"{ex.GetType().Name}: {ex.Message}" }, null, fatal: true);

    /// <summary>The plan is not valid. Recoverable: ENTER goes back.</summary>
    public static ErrorScreen ForPlan(IReadOnlyCollection<string> problems) =>
        new("Setup cannot continue with the settings as they are.",
            problems.ToArray(), null, fatal: false);

    public override string Status => _fatal
        ? "F2=Save log   F3=Quit"
        : "ENTER=Back   F2=Save log   F3=Quit";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Setup cannot continue.");
        f.Body(5, 5, _summary);

        int row = 7;
        if (_command is not null)
        {
            f.Body(row++, 7, _command, Slot.Brand);
            row++;
        }
        foreach (string line in _detail)
        {
            if (row >= f.Rows - 6) break;
            string text = line.TrimEnd();
            if (text.Length > f.BodyWidth - 14) text = text[..(f.BodyWidth - 14)];
            f.Body(row++, 7, text);
        }

        f.Body(f.Rows - 5, 5, $"A full log has been written to {Log.Path}");
        f.Body(f.Rows - 4, 5, "Press F2 to write the log to removable media.");
        if (_exportNote is not null) f.Body(f.Rows - 3, 5, _exportNote, Slot.Brand);
    }

    public override Transition Handle(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.F2:
                // Every mounted filesystem that is not the medium Setup booted
                // from would be the right target list; Phase 4 owns that screen.
                // Until then the destination is fixed and named, so "it said it
                // saved the log" and "the log is at that path" are the same
                // statement.
                string target = "/tmp/os7-setup.log";
                _exportNote = Log.Export(target, out string detail)
                    ? $"Log written to {detail}"
                    : $"Could not write the log: {detail}";
                return Transition.Redraw;

            case Key.Enter when !_fatal:
                return Transition.Back;

            default:
                return Transition.Stay;
        }
    }
}
