using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 7 — Computer name and administrator account. SETUP-PLAN §3.
///
/// Win2k asked for these in its GUI phase. OS/7 has no GUI phase, so they are
/// asked here — which is what NT 3.x did, and is why this screen list is longer
/// than Win2k's text phase rather than being a problem.
///
/// IT IS NOT OPTIONAL AND CANNOT BE SKIPPED. The squashfs contains NO USERS AT
/// ALL: casper creates the live `ubuntu` account at boot, in the overlay, so
/// none of it survives an install. A machine installed without this screen boots
/// to a login prompt nobody can get past — which is precisely what spike S3 hit.
///
/// A FORM, so TAB moves and ENTER commits. Everything else in Setup is a list or
/// a single field, and this is the one place with five things to fill in;
/// modelling it as five consecutive screens would mean five chances to go back
/// and no way to see what was typed.
/// </summary>
internal sealed class AccountScreen : Screen
{
    private readonly InstallPlan _plan;
    private string? _note;

    private enum Field { Computer, User, FullName, Password, Confirm }
    private Field _field = Field.Computer;

    private readonly TextBox _computer = new() { MaxLength = 63 };
    private readonly TextBox _user = new() { MaxLength = 32 };
    private readonly TextBox _full = new() { MaxLength = 64 };
    private readonly TextBox _pass = new() { Masked = true };
    private readonly TextBox _confirm = new() { Masked = true };

    /// <summary>
    /// Long enough to be worth having, short enough that somebody will actually
    /// set one. The disk passphrase's minimum is separate and higher — losing
    /// that one loses the data, losing this one loses a login.
    /// </summary>
    private const int MinimumPassword = 8;

    public AccountScreen(InstallPlan plan)
    {
        _plan = plan;
        // Pre-filled from the plan, so stepping back into this screen shows what
        // was typed, and an --unattend plan replayed interactively is editable.
        // The PASSWORD is deliberately not pre-filled: it is not in the plan
        // file by design, and a masked field showing a length nobody typed is a
        // field that lies about what will be set.
        _computer.Set(_plan.Account.Hostname);
        _user.Set(_plan.Account.Username);
        _full.Set(_plan.Account.FullName);
    }

    public override string Status => "TAB=Next field   ENTER=Continue   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Setup needs a name for this computer and an account to administer it.");

        int left = f.Left + 5;
        int width = Math.Min(70, f.BodyWidth - 10);
        int fieldWidth = Math.Min(40, width - 22);

        f.Box(5, left, width, 13);
        Row(f, 6, left, fieldWidth, "Computer name:", _computer, Field.Computer);
        Row(f, 8, left, fieldWidth, "User name:", _user, Field.User);
        Row(f, 10, left, fieldWidth, "Full name:", _full, Field.FullName);
        Row(f, 12, left, fieldWidth, "Password:", _pass, Field.Password);
        Row(f, 14, left, fieldWidth, "Confirm password:", _confirm, Field.Confirm);
        f.Text(16, left + 3, "The account is added to sudo and administers this machine.");

        f.Body(19, 5, "Press TAB to move between fields, then ENTER when they are correct.");
        if (_note is not null) f.Body(21, 5, _note, Slot.Brand);
    }

    private void Row(Frame f, int row, int left, int width, string label,
                     TextBox box, Field which)
    {
        f.Text(row, left + 3, label);
        box.Draw(f, row, left + 21, width, focused: _field == which);
    }

    public override Transition Handle(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Tab:
            case Key.Down:
                _field = (Field)(((int)_field + 1) % 5);
                return Transition.Redraw;

            case Key.Up:
                _field = (Field)(((int)_field + 4) % 5);
                return Transition.Redraw;

            case Key.Escape:
                return Transition.Back;

            case Key.Enter:
                return Commit();

            default:
                return Current.Handle(key) ? Transition.Redraw : Transition.Stay;
        }
    }

    private TextBox Current => _field switch
    {
        Field.Computer => _computer,
        Field.User => _user,
        Field.FullName => _full,
        Field.Password => _pass,
        _ => _confirm,
    };

    /// <summary>
    /// Everything wrong with THIS SCREEN, and nothing else.
    ///
    /// §6.6 and the Phase 2 finding behind it: a screen validates what IT
    /// collected, never the whole plan. Calling `InstallPlan.Validate` here
    /// would report "no disk selected" on a screen that has never seen a disk —
    /// which is exactly the bug screen 3 shipped with once.
    ///
    /// The checks are the ones `useradd` would make several minutes and six
    /// steps later, INSIDE THE CHROOT, where the only thing that can be said
    /// about them is an error screen naming a command nobody typed.
    /// </summary>
    private Transition Commit()
    {
        string computer = _computer.Value.Trim();
        string user = _user.Value.Trim();

        if (!AccountPlan.IsValidHostname(computer))
        {
            _note = computer.Length == 0
                ? "Type a name for this computer."
                : $"'{computer}' is not a valid computer name. Letters, digits and "
                  + "hyphens, not starting or ending with one.";
            _field = Field.Computer;
            return Transition.Redraw;
        }
        if (!AccountPlan.IsValidUsername(user))
        {
            _note = user.Length == 0
                ? "Type a user name for the account."
                : $"'{user}' is not a valid user name. Lower-case letters, digits, "
                  + "'-' and '_', starting with a letter.";
            _field = Field.User;
            return Transition.Redraw;
        }
        if (_pass.Length < MinimumPassword)
        {
            _note = $"The password must be at least {MinimumPassword} characters.";
            _field = Field.Password;
            return Transition.Redraw;
        }
        if (_confirm.Value != _pass.Value)
        {
            _note = "The two passwords are not the same. Type them again.";
            _pass.Clear();
            _confirm.Clear();
            _field = Field.Password;
            return Transition.Redraw;
        }

        _plan.Account.Hostname = computer;
        _plan.Account.Username = user;
        _plan.Account.FullName = _full.Value.Trim();
        _plan.Account.Password = _pass.Value;

        // Cleared from the widgets the moment the plan has it. The screen is
        // still on the stack - ESC comes back to it - and a rendered field is
        // one screendump away from being a password in a bug report.
        _pass.Clear();
        _confirm.Clear();

        // The account's own validation, which knows about reserved names.
        var problems = new List<string>();
        _plan.Account.Validate(problems);
        if (problems.Count > 0)
        {
            _note = problems[0];
            _field = Field.User;
            return Transition.Redraw;
        }

        // NOT the password, and not a placeholder for it either.
        Log.Info($"account: {user} ({_plan.Account.FullName}) on {computer}");
        return Transition.To(ModeScreen.Next(_plan));
    }
}
