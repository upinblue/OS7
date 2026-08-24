using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 3 — regional settings. SETUP-PLAN §3, modelled on the MS-DOS 6.22
/// settings box: a list of settings, ENTER on one to see the alternatives.
///
/// Two levels, exactly as the original did it. The summary lists what is
/// currently chosen; ENTER opens a picker for one setting; the picker's ENTER
/// stores the choice and comes back. That shape is why the screen scales from
/// three keyboard layouts to the six hundred timezones /usr/share/zoneinfo
/// actually has (L10) without becoming a different screen.
/// </summary>
internal sealed class RegionalScreen : Screen
{
    private enum Setting { Language, Keyboard, Timezone, Accept }

    private readonly InstallPlan _plan;
    private Setting _row = Setting.Language;
    private SelectionList? _picker;
    private Setting _picking;
    private Choice[] _choices = Array.Empty<Choice>();
    private int _pickerRows = 10;

    public RegionalScreen(InstallPlan plan) => _plan = plan;

    public override string Status => _picker is null
        ? "ENTER=Continue   ↑↓=Select   F3=Quit"
        : "ENTER=Choose   ESC=Cancel   ↑↓=Select";

    public override void Layout(int cols, int rows) => _pickerRows = Math.Max(4, rows - 11);

    public override void Draw(Frame f)
    {
        if (_picker is not null) { DrawPicker(f); return; }

        f.Body(3, 5, "Setup will use the following regional settings:");

        int left = f.Left + 5;
        int width = Math.Min(70, f.BodyWidth - 10);
        f.Box(5, left, width, 7);
        Row(f, 6, left, width, Setting.Language, "Language:", Describe(SystemLists.Languages, _plan.Language));
        Row(f, 7, left, width, Setting.Keyboard, "Keyboard:", Describe(SystemLists.Keyboards, _plan.Keyboard));
        Row(f, 8, left, width, Setting.Timezone, "Time zone:", Describe(SystemLists.Timezones, _plan.Timezone));
        f.Divider(9, left, width);
        Row(f, 10, left, width, Setting.Accept, "The settings are correct.", "");

        f.Body(13, 5, "If all the settings are correct, press ENTER.");
        f.Body(15, 5, "To change a setting, press the UP or DOWN ARROW keys to select it.");
        f.Body(16, 5, "Then press ENTER to see alternatives.");
    }

    private void Row(Frame f, int row, int left, int width, Setting which,
                     string label, string value)
    {
        bool selected = _row == which;
        int fg = selected ? Slot.Black : Slot.White;
        int bg = selected ? Slot.Grey : Slot.Field;
        f.Fill(row, left + 1, width - 2, ' ', fg, bg);
        f.Text(row, left + 3, label, fg, bg);
        if (value.Length > 0)
        {
            int at = left + 3 + 20;
            int room = left + width - 2 - at;
            if (value.Length > room && room > 1) value = value[..room];
            f.Text(row, at, value, fg, bg);
        }
    }

    private void DrawPicker(Frame f)
    {
        string what = _picking switch
        {
            Setting.Language => "language",
            Setting.Keyboard => "keyboard layout",
            _ => "time zone",
        };
        f.Body(3, 5, $"Select a {what}, then press ENTER.");
        int left = f.Left + 5;
        int width = Math.Min(70, f.BodyWidth - 10);
        _picker!.Draw(f, 5, left, width);
        f.Text(6 + _picker.Height, left,
               $"{_picker.Selected + 1} of {_picker.Items.Count}", Slot.Brand);
        f.Text(6 + _picker.Height, left + 20,
               "Type a letter to jump.", Slot.White);
    }

    public override Transition Handle(KeyPress key)
    {
        return _picker is null ? HandleSummary(key) : HandlePicker(key);
    }

    private Transition HandleSummary(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Up:
                _row = _row == Setting.Language ? Setting.Accept : _row - 1;
                return Transition.Redraw;

            case Key.Down:
                _row = _row == Setting.Accept ? Setting.Language : _row + 1;
                return Transition.Redraw;

            case Key.Enter when _row == Setting.Accept:
                if (!_plan.Validate(out List<string> problems))
                {
                    // Should be unreachable - every field starts valid and the
                    // picker only ever stores a value from the list. Checked
                    // anyway, because §6.6 makes the plan the single thing
                    // execution reads, and an invalid plan reaching Phase 2
                    // would be found by a partitioner.
                    Log.Error("regional settings are incomplete: " + string.Join("; ", problems));
                    return Transition.To(ErrorScreen.ForPlan(problems));
                }
                Log.Info($"regional: {_plan.Language} / {_plan.Keyboard} / {_plan.Timezone}");
                return Transition.To(new CompleteScreen(_plan));

            case Key.Enter:
                OpenPicker(_row);
                return Transition.Redraw;

            case Key.Escape:
                return Transition.Back;

            default:
                return Transition.Stay;
        }
    }

    private Transition HandlePicker(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Enter:
                Choice picked = _choices[_picker!.Selected];
                switch (_picking)
                {
                    case Setting.Language: _plan.Language = picked.Value; break;
                    case Setting.Keyboard: _plan.Keyboard = picked.Value; break;
                    default: _plan.Timezone = picked.Value; break;
                }
                Log.Info($"{_picking} = {picked.Value}");
                _picker = null;
                return Transition.Redraw;

            case Key.Escape:
                _picker = null;
                return Transition.Redraw;

            default:
                return _picker!.Handle(key) ? Transition.Redraw : Transition.Stay;
        }
    }

    private void OpenPicker(Setting which)
    {
        _picking = which;
        _choices = which switch
        {
            Setting.Language => SystemLists.Languages,
            Setting.Keyboard => SystemLists.Keyboards,
            _ => SystemLists.Timezones,
        };
        string current = which switch
        {
            Setting.Language => _plan.Language,
            Setting.Keyboard => _plan.Keyboard,
            _ => _plan.Timezone,
        };
        string[] labels = new string[_choices.Length];
        int at = 0;
        for (int i = 0; i < _choices.Length; i++)
        {
            labels[i] = _choices[i].Label;
            if (_choices[i].Value == current) at = i;
        }
        _picker = new SelectionList(labels, _pickerRows, at);
    }

    private static string Describe(Choice[] choices, string value)
    {
        foreach (Choice c in choices)
            if (c.Value == value) return c.Label;
        // The plan carries something the running system does not offer - an
        // --unattend file written for a different image, most likely. Shown as
        // it is rather than silently replaced, because replacing it is how an
        // unattended install quietly does the wrong thing.
        return value;
    }
}
