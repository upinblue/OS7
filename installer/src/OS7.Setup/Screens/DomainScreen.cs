using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Steps;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 9D — joining an Active Directory domain. SETUP-PLAN §3, D16.
///
/// Lettered rather than numbered, for 9S's reason: it hangs off the network
/// screens and is not a step every install walks. It comes after 9, 9W and 9S
/// because a join needs DNS, a route and a clock, and those are what screen 9
/// just configured and tested.
///
/// A FORM, so TAB moves and ENTER commits — the same object as screens 7 and 9S.
/// Five fields, and the last one is a secret that is never written down: the
/// join runs during the install, while the password is in memory, and nothing
/// carries it to a first boot (see `DomainPlan` for why that is the opposite of
/// what the TPM step concluded, and why the reason is different).
///
/// THE DOMAIN FIELD IS THE ON/OFF SWITCH, and there is no list to choose it
/// with. Blank means this computer is installed without joining, which is what
/// nearly every machine wants, and the screen says so where the operator is
/// looking rather than hiding it behind a third widget. It is `NetworkMethod`'s
/// "leave this computer without a network" written as an empty field, and it is
/// recorded as an explicit answer either way (L23's rule).
///
/// AND THE JOIN ACCOUNT DECIDES WHICH CREDENTIAL THIS IS. Blank means the
/// computer account already exists in the directory and the password below is
/// its one-time password — which is how a machine gets joined without a domain
/// administrator's password being typed onto a console in a room. Filled in, it
/// names a user allowed to create the account. One field, two meanings, and the
/// line above the note says which one is in force right now.
///
/// EVERY ACTION KEY HERE IS AN F-KEY. `TextBox` consumes letters as text, so a
/// `T` for Test would mean two things depending on where the cursor was — the
/// one property a keyboard-driven installer cannot afford, and the same reason
/// the three network screens use F4 and F6.
/// </summary>
internal sealed class DomainScreen : Screen
{
    private readonly InstallPlan _plan;
    private string? _note;
    private bool _noteIsGood;
    private bool _probing;

    private enum Field { Realm, Computer, Ou, Account, Password }
    private Field _field = Field.Realm;

    // A domain name is at most 255 characters and a host label at most 63; the
    // computer field takes a full label rather than the fifteen the directory
    // can hold, because a field that silently stops accepting the sixteenth
    // character of a name somebody is copying off a sheet of paper is worse
    // than one that says why. The rule is enforced in Collect, where it can be
    // explained.
    private readonly TextBox _realm = new() { MaxLength = 96 };
    private readonly TextBox _computer = new() { MaxLength = 63 };
    private readonly TextBox _ou = new() { MaxLength = 200 };
    private readonly TextBox _account = new() { MaxLength = 64 };
    private readonly TextBox _password = new() { Masked = true };

    public DomainScreen(InstallPlan plan)
    {
        _plan = plan;
        DomainPlan d = plan.Domain;

        // Pre-filled from the plan, so ESC back into this screen shows what was
        // typed and an --unattend plan replayed interactively is editable. The
        // PASSWORD is deliberately not pre-filled, for AccountScreen's reason: a
        // masked field showing a length nobody typed is a field that lies about
        // what will be sent.
        _realm.Set(d.Realm ?? "");
        // The computer's name from screen 7, because that is the right answer
        // nearly always — sssd derives the host principal from the machine's own
        // name, and a machine the directory and the hostname disagree about is a
        // machine two tools disagree about. Editable, because a hostname may be
        // longer than a computer account name can be.
        _computer.Set(d.ComputerName ?? plan.Account.Hostname);
        _ou.Set(d.OrganizationalUnit ?? "");
        _account.Set(d.JoinAccount ?? "");
    }

    /// <summary>
    /// The probe runs on the first idle tick after F4, never inside Handle's own
    /// keystroke.
    ///
    /// WifiScreen's reason, measured there rather than reasoned about here: the
    /// flow's order is Layout → Draw → Show → Read, so work done while answering
    /// a key happens BEFORE the frame that would explain it reaches the console.
    /// A DNS lookup and up to four connection attempts is eight seconds of a
    /// screen that has not changed. Ticking costs one frame and gets the order
    /// right — "Testing …" is drawn and shown, and the tick 200 ms later does
    /// the work.
    /// </summary>
    public override bool Ticks => _probing;

    public override string Status =>
        "TAB=Next field   F4=Test   ENTER=Continue   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Setup can join this computer to an Active Directory domain.");

        int left = f.Left + 5;
        int width = f.BoxWidth;
        int fieldWidth = Math.Min(40, width - 22);

        f.Box(5, left, width, 13);
        Row(f, 6, left, fieldWidth, "Domain:", _realm, Field.Realm);
        Row(f, 8, left, fieldWidth, "Computer name:", _computer, Field.Computer);
        Row(f, 10, left, fieldWidth, "Computer OU:", _ou, Field.Ou);
        Row(f, 12, left, fieldWidth, "Join account:", _account, Field.Account);
        Row(f, 14, left, fieldWidth, "Password:", _password, Field.Password);

        // WHICH CREDENTIAL THIS IS, next to the field it is about and derived
        // from the field above it — never from a setting somewhere else that
        // could disagree with what is on the screen.
        f.Text(16, left + 3,
               _account.Length == 0
                   ? "The password is the one-time password of a pre-created account."
                   : "That account's password; it must be allowed to join computers.");

        f.Body(18, 5, "The join happens while Setup runs, so the password is never");
        f.Body(19, 5, "written to this computer. Leave the domain blank not to join.");

        if (_note is not null)
            f.Body(21, 5, _note, _noteIsGood ? Slot.White : Slot.Brand);
        else if (_plan.Domain.Verified)
            f.Body(21, 5, $"Tested: {_plan.Domain.VerifiedDetail}");
        else if (_realm.Length > 0)
            f.Body(21, 5, "Not yet tested.", Slot.Brand);
        else
            f.Body(21, 5, "This computer will not be joined to a domain.");
    }

    private void Row(Frame f, int row, int left, int width, string label,
                     TextBox box, Field which)
    {
        f.Text(row, left + 3, label);
        box.Draw(f, row, left + 21, width, _field == which);
    }

    public override Transition Handle(KeyPress key)
    {
        // The tick that F4 asked for. It arrives once, after the "Testing …"
        // frame is already on the console; any key pressed inside that 200 ms
        // spends itself on the same thing, which is WifiScreen's behaviour and
        // the same trade.
        if (_probing)
        {
            _probing = false;
            (bool ok, string detail) = DomainProbe.Test(_plan.Domain);
            _note = detail;
            _noteIsGood = ok;
            return Transition.Redraw;
        }

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

            // F4 tests the DOMAIN, not the credential, so it does not ask for a
            // password first: refusing to look for a domain controller until a
            // password has been typed would refuse the one check that is useful
            // before anybody knows whether the password is needed.
            case Key.F4:
                if (!Collect(withCredential: false)) return Transition.Redraw;
                if (!_plan.Domain.Join)
                {
                    _note = "There is nothing to test: no domain was typed.";
                    _noteIsGood = false;
                    return Transition.Redraw;
                }
                _note = $"Testing {_plan.Domain.Realm} …";
                _noteIsGood = true;
                _probing = true;
                return Transition.Redraw;

            case Key.Enter:
                if (!Collect(withCredential: true)) return Transition.Redraw;
                // Start, not `new`: the whole-plan check lives behind that
                // factory and the constructor is private. This is the last ENTER
                // before a disk is written on every path that reaches 9D.
                return Transition.To(ExecuteScreen.Start(_plan));

            default:
                TextBox box = _field switch
                {
                    Field.Realm => _realm,
                    Field.Computer => _computer,
                    Field.Ou => _ou,
                    Field.Account => _account,
                    _ => _password,
                };
                if (!box.Handle(key)) return Transition.Stay;
                _note = null;
                return Transition.Redraw;
        }
    }

    /// <summary>
    /// What THIS screen collected, checked here and nowhere else.
    ///
    /// BUILD-NOTES #45 in its general form: the whole-plan check runs at
    /// `ExecuteScreen.Start`, and a screen may only be refused for something it
    /// could have got right. Every field checked below is on this screen.
    ///
    /// `withCredential` is false for F4 and true for ENTER, which is the one
    /// place the two differ: the probe needs a domain and the join needs a
    /// password as well.
    /// </summary>
    private bool Collect(bool withCredential)
    {
        DomainPlan d = _plan.Domain;
        string realm = _realm.Value.Trim();

        if (realm.Length == 0)
        {
            NotJoined(d);
            Log.Info("domain: none (chosen)");
            return true;
        }

        var problems = new List<string>();

        if (!DomainPlan.IsValidDomainName(realm))
            problems.Add($"'{realm}' is not a domain name, like corp.example.com");

        string computer = _computer.Value.Trim();
        if (computer.Length == 0)
            problems.Add("Type the name this computer will have in the directory.");
        else if (computer.Length > DomainPlan.MaximumComputerName)
            problems.Add($"'{computer}' is longer than {DomainPlan.MaximumComputerName} "
                         + "characters, which is all a computer account name can be.");
        else if (!DomainPlan.IsValidComputerName(computer))
            problems.Add($"'{computer}' is not a valid computer name. Letters, digits "
                         + "and hyphens, not starting or ending with one.");

        string ou = _ou.Value.Trim();
        if (ou.Length > 0 && !ou.Contains('='))
            problems.Add("The OU is a distinguished name, like OU=Linux,DC=corp,DC=example,DC=com.");
        else if (ou.Length > 0 && !DomainPlan.IsSafeInSingleQuotes(ou))
            problems.Add("The OU cannot contain a quotation mark.");

        string account = _account.Value.Trim();
        if (account.Length > 0
            && (account.Contains(' ') || !DomainPlan.IsSafeInSingleQuotes(account)))
            problems.Add($"'{account}' is not an account name. Leave it blank to use a "
                         + "one-time password.");

        // THE FIELD IS EMPTY AFTER A PASSWORD HAS BEEN TYPED, and it is empty on
        // purpose — see below. So what is demanded here is a password SETUP does
        // not have, not a password this widget is not holding: the gate at
        // `ExecuteScreen.Start` can refuse the plan for another screen's field,
        // and ESC comes back to this same instance, where demanding the domain
        // password a second time is a screen refusing to continue over an answer
        // it already has.
        if (withCredential && _password.Length == 0 && string.IsNullOrEmpty(d.Password))
            problems.Add(account.Length == 0
                ? "Type the one-time password of the pre-created computer account."
                : $"Type the password for {account}.");

        if (problems.Count > 0)
        {
            _note = problems[0];
            _noteIsGood = false;
            return false;
        }

        d.Join = true;
        d.Realm = realm;
        d.ComputerName = computer;
        d.OrganizationalUnit = ou.Length > 0 ? ou : null;
        d.JoinAccount = account.Length > 0 ? account : null;
        // ONLY WHEN THE FIELD HOLDS ONE. An empty field on a second pass is "the
        // password has already been taken", not "there is no password" — the
        // check above has just established that one of the two is true — and
        // assigning it unconditionally would empty the plan of a secret nobody
        // can retype without knowing they have to.
        if (withCredential && _password.Length > 0)
        {
            d.Password = _password.Value;
            // Cleared from the widget the moment the plan has it, for
            // AccountScreen's reason: the screen is still on the stack, ESC
            // comes back to it, and a rendered field is one screendump away
            // from being a domain password in a bug report.
            _password.Clear();
        }

        // NOT THE PASSWORD, and not its length either — a length in a log that
        // is also on a screendump is most of a short password.
        Log.Info($"domain: {d.Realm} as {d.ComputerName}"
                 + (d.OrganizationalUnit is null ? "" : $" in {d.OrganizationalUnit}")
                 + (d.UsesOneTimePassword ? " (one-time password)" : $" via {d.JoinAccount}"));
        return true;
    }

    /// <summary>
    /// This computer is not joining a domain — ALL SEVEN FIELDS, in one place.
    ///
    /// AN ANSWER, NOT AN ABSENCE, and the rest is cleared so that a half-typed
    /// domain from a previous pass cannot survive into a machine that was chosen
    /// not to join one — the same clearing `NetworkScreen` does for
    /// `NetworkMethod.None`. `Join = false` beside a realm, a join account and a
    /// successful F4 is a plan whose log line contradicts itself, and the log
    /// line is all anybody has afterwards.
    ///
    /// One method and not two copies of one rule, because the two callers are
    /// the two ways to answer "no" — the domain field left blank, and the screen
    /// never shown at all — and a rule written twice is BUILD-NOTES #66 in
    /// miniature.
    /// </summary>
    private static void NotJoined(DomainPlan d)
    {
        d.Join = false;
        d.Realm = null;
        d.ComputerName = null;
        d.OrganizationalUnit = null;
        d.JoinAccount = null;
        d.Password = null;
        d.Verified = false;
        d.VerifiedDetail = null;
    }

    /// <summary>
    /// Why this screen cannot be shown on this machine, or null.
    ///
    /// A REASON RATHER THAN A BOOLEAN, and that is deliberate: the log line on
    /// the skipped path has to say WHY, and a `bool` would make the caller
    /// derive the reason a second time — a second place for the same answer to
    /// be wrong. `ModeScreen.Applies` gets away with a boolean because there is
    /// only ever one reason.
    /// </summary>
    public static string? Unavailable(InstallPlan plan)
    {
        if (plan.Network.Method == NetworkMethod.None)
            return "this computer has no network";

        // Measured 2026-08-27: `adcli` is on no ISO this repository has built
        // (out/OS7-1.0.0.116-amd64.packages.manifest, 1 491 packages). Until it
        // is in a package list, this is the branch every install takes — L35.
        if (DomainProbe.MissingTool is { } tool)
            return $"{tool} is not on this setup medium";

        return null;
    }

    /// <summary>
    /// The screen after 9, 9W and 9S — or the one after that where there is
    /// nothing to ask.
    ///
    /// The same shape as `NetworkScreen.Entry` and `ModeScreen.Next`: the
    /// question "is there anything to ask here" belongs to the screen that would
    /// ask it. A machine with no network cannot join a domain and a medium with
    /// no `adcli` cannot join one either, and in both cases the plan RECORDS
    /// the answer rather than leaving the field at its default — an install
    /// that did not ask and an install that was told "no" must not read the same
    /// afterwards (L23's rule, and #45 read from the other end: a skipped screen
    /// must not also skip the gate behind it).
    /// </summary>
    public static Screen Entry(InstallPlan plan)
    {
        string? why = Unavailable(plan);
        if (why is null) return new DomainScreen(plan);

        // THE WHOLE ANSWER, not the switch alone: this path is reached with a
        // plan that may already carry a realm and a credential — an --unattend
        // plan replayed interactively, or a pass through this screen followed by
        // ESC back to screen 9 and a network turned off there.
        NotJoined(plan.Domain);
        Log.Info($"domain: not joined ({why}; screen 9D skipped)");
        // The SAME door as the branch above, and the only door in front of the
        // executor.
        return ExecuteScreen.Start(plan);
    }
}
