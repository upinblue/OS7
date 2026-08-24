using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Screens;
using OS7.Setup.Steps;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup;

/// <summary>
/// os7-setup — OS/7's text-mode installer. installer/SETUP-PLAN.md is the design.
///
///     os7-setup                          run interactively on this terminal
///     os7-setup --unattend plan.json     run it from a file, no UI (§6.6)
///     os7-setup --passphrase-file f      where the disk passphrase comes from
///     os7-setup --password-file f        where the account password comes from
///     os7-setup --storage-only           prepare the disk and stop
///     os7-setup --dry-run                print every command instead of running it
///     os7-setup --print-plan             write the default plan as JSON and exit
///     os7-setup --self-test              check what fails silently, and exit
///     os7-setup --geometry 80x25         force the canvas size (§2.4)
///
/// PHASE 3. The flow is Welcome -> Licence -> Regional -> Disk -> Layout ->
/// Confirm -> Account -> Mode -> (install) -> Complete. Screen 6 is the gate and
/// screen 10 is where the writing starts, so the disk is still untouched while
/// the account is typed.
///
/// THE RESULT BOOTS. The system is copied, an account exists, the initramfs can
/// unlock and import, and the bootloader menu resolves a boot environment - each
/// of those checked by the step that did it, because "the installer said it
/// worked" is the class of evidence this project has been bitten by repeatedly.
///
/// Screen 9 (network) is not here: DHCP is the default and a machine that boots
/// can be configured. It is the one screen of 7-11 still outstanding.
/// </summary>
internal static class Program
{
    private static int Main(string[] args)
    {
        var options = Options.Parse(args);
        if (options.Error is not null)
        {
            Console.Error.WriteLine($"os7-setup: {options.Error}");
            Console.Error.WriteLine(Usage);
            return 2;
        }
        if (options.Help) { Console.Out.WriteLine(Usage); return 0; }

        if (options.Version)
        {
            // Before the log is opened and before anything touches a terminal:
            // `os7-setup --version` has to work on the tty2 rescue shell of a
            // machine where the thing being diagnosed is Setup itself.
            Release r = Release.Current;
            Console.Out.WriteLine(r.Display);
            if (r.Known)
            {
                Console.Out.WriteLine($"base:     Ubuntu {r.BaseRelease ?? "?"}");
                Console.Out.WriteLine($"archive:  {r.ArchiveSnapshot ?? "not pinned"}");
                if (!r.Reproducible)
                    Console.Out.WriteLine("source:   not a clean tree - this build is not reproducible");
            }
            else
            {
                Console.Out.WriteLine($"no release manifest at {Release.Path}");
            }
            return 0;
        }

        Log.Info($"os7-setup starting ({string.Join(' ', args)})");
        Log.Info($"release: {Release.Current.Display} "
                 + $"(manifest {(Release.Current.Known ? Release.Path : "absent")})");

        if (options.PrintPlan)
        {
            // §6.6's --dry-run --print-plan, in the only form Phase 1 can honour:
            // the plan a fresh run starts from. Phase 2 makes it the plan the
            // screens produced.
            Console.Out.WriteLine(new InstallPlan().ToJson());
            return 0;
        }

        if (options.SelfTest) return SelfTest();
        if (options.Unattend is not null) return Unattended(options);

        try
        {
            Geometry geometry = Geometry.FromCommandLine(options.Geometry);
            using Terminal terminal = Terminal.Acquire(geometry);
            var plan = new InstallPlan();
            if (options.DryRun) Log.Warn("--dry-run: no command will actually be run");
            ExecuteScreen.DryRun = options.DryRun;
            var flow = new SetupFlow(terminal, new WelcomeScreen(plan));

            FlowResult result = flow.Run();
            Log.Info($"flow ended: {result}");
            terminal.Restore();

            // 0 finished, 1 quit. The systemd unit reads this to decide between
            // rebooting and dropping to a shell, so the two have to differ.
            return result == FlowResult.Finished ? 0 : 1;
        }
        catch (Exception ex)
        {
            // Last resort. Anything reaching here happened before or after the
            // terminal existed, so there is no screen to show it on - it goes to
            // the log and to stderr, which on tty1 is the console anyway.
            Log.Error($"unhandled: {ex}");
            Console.Error.WriteLine($"os7-setup: {ex.GetType().Name}: {ex.Message}");
            Console.Error.WriteLine($"A log is at {Log.Path}");
            return 3;
        }
        finally
        {
            Log.Close();
        }
    }

    /// <summary>
    /// `--unattend plan.json` — §6.6's whole point.
    ///
    /// The interactive screens exist only to fill in an InstallPlan, and
    /// execution happens strictly afterwards from that object alone. So the
    /// unattended path is not a parallel implementation: it loads the same
    /// object, validates it with the same code, and runs the same steps. If
    /// those two ever diverge, one of them is wrong and it will be this one.
    ///
    /// THE PASSPHRASE IS NOT IN THE PLAN and never will be — a plan file goes
    /// into a repository, a log and a screenshot. `--passphrase-file` is a
    /// separate artefact, read once and not kept.
    /// </summary>
    private static int Unattended(Options o)
    {
        try
        {
            string json = File.ReadAllText(o.Unattend!);
            InstallPlan? plan = InstallPlan.FromJson(json);
            if (plan is null)
            {
                Console.Error.WriteLine($"os7-setup: {o.Unattend} is not an install plan");
                return 2;
            }

            if (o.PassphraseFile is not null)
            {
                // TrimEnd on newlines only: a passphrase may legitimately begin
                // or end with a space, and an editor will have appended a
                // newline that was never part of it.
                plan.Storage.Passphrase = File.ReadAllText(o.PassphraseFile).TrimEnd('\r', '\n');
                Log.Info($"passphrase read from {o.PassphraseFile} "
                         + $"({plan.Storage.Passphrase.Length} characters)");
            }
            if (o.PasswordFile is not null)
            {
                // A SECOND FILE, not a second field in the same one. The disk
                // passphrase and the account password are different secrets with
                // different consequences - losing the first loses the data,
                // losing the second loses a login - and a fleet that rotates one
                // should not have to rewrite the other.
                plan.Account.Password = File.ReadAllText(o.PasswordFile).TrimEnd('\r', '\n');
                Log.Info($"account password read from {o.PasswordFile} "
                         + $"({plan.Account.Password.Length} characters)");
            }

            // `--storage-only` stops before the account exists, so demanding one
            // would refuse a plan that is complete for what it is being asked to
            // do. Same argument as a screen validating only what it collected.
            var problems = new List<string>();
            if (o.StorageOnly)
            {
                plan.Storage.Validate(problems);
            }
            else if (!plan.Validate(out problems))
            {
                // filled by Validate
            }
            if (problems.Count > 0)
            {
                foreach (string p in problems) Console.Error.WriteLine($"os7-setup: {p}");
                Log.Error("unattended plan is not valid: " + string.Join("; ", problems));
                return 2;
            }

            Log.Info($"unattended{(o.DryRun ? " (dry run)" : "")}: {plan.ToJson().ReplaceLineEndings(" ")}");
            var executor = new Executor(o.DryRun);
            var target = TargetRoot.Install;

            // `--storage-only` exists for the harness that predates Phase 3 and
            // for anyone who wants the disk prepared without a system on it. The
            // DEFAULT is the whole install, because an installer whose unattended
            // mode does less than its interactive mode is an installer whose
            // unattended mode is not tested by the same thing (§6.6).
            List<IStep> steps = o.StorageOnly
                ? StorageSteps.For(plan)
                : SystemSteps.Everything(plan, target);

            executor.Run(steps,
                         (step, done, total) =>
                             Console.Out.WriteLine($"OS7-SETUP [{done}/{total}] {step}"));
            Console.Out.WriteLine(o.StorageOnly ? "OS7-SETUP-DONE storage"
                                                : "OS7-SETUP-DONE install");
            return 0;
        }
        catch (StepException ex)
        {
            // The same three facts the error screen would have shown, because a
            // CI log is the error screen when there is no screen.
            Console.Error.WriteLine($"OS7-SETUP-FAILED {ex.Message}");
            Console.Error.WriteLine($"  command: {ex.Command}");
            Console.Error.WriteLine($"  output:  {ex.Output.ReplaceLineEndings(" | ")}");
            return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"OS7-SETUP-FAILED {ex.GetType().Name}: {ex.Message}");
            Log.Error($"unattended: {ex}");
            return 3;
        }
    }

    /// <summary>
    /// The checks that would otherwise fail as "the screen looks wrong".
    ///
    /// Every item here is something spike S1 found the hard way, or something
    /// that has no visible symptom until a screen is already on the console. It
    /// runs without touching the terminal, so the harness can call it over a
    /// serial line before it tries to drive anything.
    /// </summary>
    private static int SelfTest()
    {
        int bad = 0, absent = 0;
        void Check(bool ok, string what, string detail = "")
        {
            Console.Out.WriteLine($"SELFTEST {(ok ? "ok  " : "FAIL")} {what}"
                                  + (detail.Length > 0 ? $" — {detail}" : ""));
            if (!ok) bad++;
        }

        // A check on a FILE THE IMAGE PROVIDES rather than on this binary's own
        // logic. Both are fatal — hook 0080 runs this inside the chroot and a
        // missing palette or manifest has to fail the ISO build. But the two
        // failures mean completely different things to whoever is reading, and
        // the difference is invisible from the exit code alone:
        //
        //   in the image   a missing file is a broken build
        //   outside it     it is Tuesday. `dotnet publish` into /tmp and run this
        //                  and NONE of these files exist, because they belong to
        //                  the image, not to the compiler.
        //
        // So they are counted separately and the summary says so. Without that,
        // a developer building the binary alone sees eleven failures and has no
        // way to tell which ones are theirs.
        void CheckImage(bool ok, string what, string detail = "")
        {
            Check(ok, what, detail);
            if (!ok) absent++;
        }

        List<string> conflicts = Input.PrefixConflicts();
        Check(conflicts.Count == 0, "key table unambiguous",
              conflicts.Count == 0 ? "" : string.Join("; ", conflicts));

        foreach (Palette p in new[] { Palette.Default, Palette.HighContrast })
            CheckImage(File.Exists(Themes.PaletteFile(p)), $"palette {p}", Themes.PaletteFile(p));

        // Both fonts, and the rule that picks between them. The (1280, 800) case
        // has to come out 16x32: that is the reference geometry, and getting it
        // wrong draws a correct 80x25 screen into a quarter of the framebuffer.
        foreach ((int w, int h, string want) in new[]
                 {
                     (1280, 800, "16x32"), (1920, 1080, "16x32"),
                     (1024, 768, "8x16"), (640, 480, "8x16"),
                 })
        {
            ConsoleFont f = Themes.PickFont(w, h);
            (int cols, int rows) = f.GridOn(w, h);
            CheckImage(File.Exists(f.Path) && f.Path.Contains(want) && cols >= 80 && rows >= 25,
                  $"console font for {w}x{h} is {want} -> {cols}x{rows}", f.Path);
        }

        CheckImage(File.Exists(LicenceScreen.Path), "licence text", LicenceScreen.Path);

        // ---------------------------------------------------------------------
        // The release manifest.
        //
        // This runs inside the chroot during the ISO build (hook 0080), AFTER
        // hook 0075 has written the manifest — the hooks are numbered that way
        // on purpose. So a build in which the version never got written fails
        // HERE, rather than shipping an ISO whose every screen reads
        // "Version unknown" and whose boot environments are named 0.0.0.0.
        //
        // It is also the check that keeps the two halves of the version story
        // together: the same file this reads is the one the OS7 module reads to
        // name a boot environment, so Setup's title bar and the dataset on the
        // disk cannot end up quoting different numbers.
        Release release = Release.Current;
        CheckImage(release.Known, "release manifest", release.Known ? Release.Path
                                                               : $"{Release.Path} is missing");
        CheckImage(release.Version != "0.0.0.0",
              "the release has a version", release.Version);
        CheckImage(release.ArchiveSnapshot is not null,
              "the archive is pinned", release.ArchiveSnapshot ?? "no archive_snapshot in the manifest");

        // The reader must survive a manifest it does not like without taking an
        // install with it — metadata is not worth refusing to partition a disk
        // over. Checked with real files rather than reasoned about, because
        // "returns Unknown on bad input" is exactly the kind of claim that is
        // true until the first NullReferenceException.
        string tmp = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
                                            $"os7-selftest-{Environment.ProcessId}.json");
        try
        {
            File.WriteAllText(tmp, "{\"version\":\"9.9.9.9\",\"channel\":\"preview\","
                                   + "\"reproducible\":true,\"base\":{\"release\":\"26.04\","
                                   + "\"archive_snapshot\":\"20260824T000000Z\"}}");
            Release good = Release.Load(tmp);
            Check(good.Known && good.Version == "9.9.9.9" && good.Channel == "preview"
                  && good.ArchiveSnapshot == "20260824T000000Z",
                  "a manifest round-trips through the reader", good.Short);

            File.WriteAllText(tmp, "{ this is not json");
            Check(!Release.Load(tmp).Known, "a corrupt manifest reads as unknown");

            File.WriteAllText(tmp, "{}");
            Check(!Release.Load(tmp).Known, "a manifest with no version reads as unknown");

            Check(!Release.Load("/nonexistent/release.json").Known,
                  "a missing manifest reads as unknown");
        }
        finally { try { File.Delete(tmp); } catch { /* a temp file, not a result */ } }

        // The title row has to hold both strings at the reference geometry, and
        // drop the version rather than mangle it when it cannot.
        //
        // Read out of the CELL BUFFER, not out of Render(). Render() emits
        // cursor-positioning and SGR escapes and no newlines at all, so
        // `Render().Split('\n')[0]` is the whole screen and any length test on it
        // measures escape sequences. That was this check's first version, and it
        // failed a correct 80-column title row - a diagnostic that did not check
        // the thing it claimed to.
        string TitleRow(Frame frame)
        {
            var sb = new System.Text.StringBuilder(frame.Cols);
            for (int c = 0; c < frame.Cols; c++) sb.Append(frame[0, c].Rune);
            return sb.ToString();
        }
        {
            var f = new Frame(80, 25);
            f.Chrome("OS/7 Setup", "ENTER=Continue", release.TitleBar);
            string row = TitleRow(f);
            Check(row.Length == 80
                  && row.StartsWith(" OS/7 Setup")
                  && row.EndsWith(release.TitleBar + " "),
                  "the title row carries the version, right-aligned, at 80 columns",
                  $"[{row}]");

            // A half-printed version number still reads as a version number, so
            // too narrow must mean absent rather than truncated.
            var narrow = new Frame(24, 25);
            narrow.Chrome("OS/7 Setup", "", "Version 1.0.0.32 (development)");
            string narrowRow = TitleRow(narrow);
            Check(narrowRow.Contains("OS/7 Setup") && !narrowRow.Contains("Version")
                  && !narrowRow.Contains("1.0.0"),
                  "a narrow title row drops the version instead of truncating it",
                  $"[{narrowRow}]");

            // The boundary: exactly wide enough, and one column short of it.
            // " OS/7 Setup" is 11 columns, then two of gap, then the string, then
            // the one column of right margin the title row keeps.
            const string stamp = "Version 9.9.9.9";
            int exact = 1 + "OS/7 Setup".Length + 2 + stamp.Length + 1;
            var fit = new Frame(exact, 25);
            fit.Chrome("OS/7 Setup", "", stamp);
            var tight = new Frame(exact - 1, 25);
            tight.Chrome("OS/7 Setup", "", stamp);
            Check(TitleRow(fit).Contains(stamp) && !TitleRow(tight).Contains(stamp),
                  $"the version appears at {exact} columns and not at {exact - 1}",
                  $"[{TitleRow(fit)}] / [{TitleRow(tight)}]");
        }

        // ---------------------------------------------------------------------
        // Screen 4's rows, DRAWN AND READ BACK rather than measured.
        //
        // The bug this replaces was three numbers that had to agree and did not:
        // the box DiskScreen draws, the row width it built its labels for, and
        // §3.1's column arithmetic inside Describe. Every one of them was a
        // literal, none of them was checked against the others, and the symptom
        // was that `-- SETUP MEDIUM --` came out `-- SETUP MEDIUM -` — a marker
        // L12 requires, rendered as what looks like a typo.
        //
        // So this does not re-do the arithmetic; re-doing it is how the numbers
        // got out of step. It builds a row the way screen 4 builds one, draws it
        // through the widget screen 4 draws it through, at the box width screen
        // 4 asks for, and reads the cells back. Anything that eats a character
        // between Describe and the glass fails here.
        {
            // §2.4's reference geometry, which is what §3.1 is drawn at.
            const int cols = 80;
            int box = DiskScreen.BoxWidth(cols);
            int room = SelectionList.TextWidth(box);

            // The whole 80-column row, borders included, so a failure prints what
            // is actually on the screen; and the row's TEXT span on its own, so
            // "drawn whole" is asked of the text and not of the box around it.
            (string Row, string Text) RowOnScreen(Disk d)
            {
                var frame = new Frame(cols, 25);
                int left = frame.Left + 5;
                new SelectionList(new[] { d.Describe(room) }, 1).Draw(frame, 7, left, box);
                var sb = new System.Text.StringBuilder(frame.Cols);
                for (int c = 0; c < frame.Cols; c++) sb.Append(frame[8, c].Rune);
                string row = sb.ToString();
                return (row.TrimEnd(), row.Substring(left + 2, room).TrimEnd());
            }

            Disk Probe(string name, long bytes, string model, Refusal? blocker,
                       string ptType = "", int parts = 0, bool os7 = false) =>
                new(Path: "/dev/" + name, StablePath: "/dev/disk/by-id/" + name, Name: name,
                    Bytes: bytes, Model: model, Serial: "", PartitionTable: ptType,
                    Partitions: parts, Blocker: blocker,
                    PartitionLabels: Array.Empty<(string, string)>(), Os7Layout: os7);

            Check(box == 70 && room == 66,
                  "screen 4's box is 70 columns and gives a row 66", $"box {box}, row {room}");

            // Every last-column string screen 4 can produce, INCLUDING the two
            // that do not appear in .vm/phase2's screendumps because that VM has
            // neither a small disk nor a mounted one.
            foreach ((string what, Disk disk) in new (string, Disk)[]
                     {
                         ("-- SETUP MEDIUM --", Probe("vda", 2_147_483_648, "", new Refusal("setup medium"))),
                         ("-- READ-ONLY --", Probe("sr0", 900_000_000_000, "QEMU DVD-ROM", new Refusal("read-only"))),
                         ("-- IN USE --", Probe("sda", 900_000_000_000, "ATA WDC WD10EZEX-08W",
                                                new Refusal("in use", "in use at /var/lib/docker"))),
                         ("-- TOO SMALL --", Probe("sdb", 8_000_000_000, "SanDisk Cruzer Blade",
                                                  new Refusal("too small", "too small (needs 16 GB)"))),
                         ("OS/7 installation", Probe("vdb", 25_769_803_776, "", null, "gpt", 3, os7: true)),
                         ("empty", Probe("sdc", 900_000_000_000, "ATA WDC WD10EZEX-08W", null)),
                         // 128 is the GPT limit, so this is the longest this
                         // column can get without a refusal in it.
                         ("GPT, 128 partitions", Probe("nvme0n1", 953_000_000_000,
                                                       "SAMSUNG MZVL21T0HCLR-00B", null, "gpt", 128)),
                     })
            {
                (string row, string text) = RowOnScreen(disk);
                Check(text.EndsWith(what, StringComparison.Ordinal),
                      $"screen 4 draws '{what}' whole", $"[{row}]");
            }

            // And the column positions, on the §3.1 mockup's OWN disk, so the
            // numbers are checked against the drawing rather than against this
            // code's opinion of it. The name lands at 7 rather than the mockup's
            // 8 because the widget pads by one column where the mockup pads by
            // two; what §3.1 pins is the spacing INSIDE the row, and that is
            // 10 / 25 / 9 / 3.
            string mock = RowOnScreen(Probe("nvme0n1", 953_000_000_000,
                                            "SAMSUNG MZVL21T0HCLR-00B", null, "gpt", 3)).Row;
            Check(mock.IndexOf("nvme0n1", StringComparison.Ordinal) == 7
                  && mock.IndexOf("SAMSUNG", StringComparison.Ordinal) == 17
                  && mock.IndexOf("953 GB", StringComparison.Ordinal) == 45
                  && mock.IndexOf("GPT, 3 partitions", StringComparison.Ordinal) == 54,
                  "the §3.1 columns land where §3.1 draws them", $"[{mock}]");
        }

        // The plan has to survive a round trip through source-generated JSON.
        // Under NativeAOT the reflection serialiser is trimmed away, so this is
        // the check that the generator was wired up at all (spike S2).
        var plan = new InstallPlan { Timezone = "Europe/Berlin", Intent = Intent.Repair };
        InstallPlan? back = InstallPlan.FromJson(plan.ToJson());
        Check(back is not null && back.Timezone == "Europe/Berlin" && back.Intent == Intent.Repair,
              "install plan round-trips through JSON");

        // The plan must REFUSE an empty storage half. This is the check that
        // keeps --unattend from partitioning something because a field was
        // missing rather than because it was chosen.
        var empty = new InstallPlan();
        bool refused = !empty.Validate(out List<string> why);
        Check(refused && why.Any(w => w.Contains("disk")),
              "an empty plan is refused", string.Join("; ", why));

        var encrypted = new InstallPlan
        {
            Storage = { Disk = "/dev/disk/by-id/x", Encrypt = true },
        };
        Check(!encrypted.Validate(out List<string> why2)
              && why2.Any(w => w.Contains("passphrase")),
              "encryption without a passphrase is refused", string.Join("; ", why2));

        // And the passphrase must never reach the plan file. §6.6 makes that
        // file something a person keeps; this is the check that keeps the secret
        // out of it.
        var secret = new InstallPlan
        {
            Storage = { Disk = "/dev/disk/by-id/x", Passphrase = "correct horse battery" },
        };
        Check(!secret.ToJson().Contains("correct horse"),
              "the passphrase is not serialised into the plan");

        // Reading a version out of a boot-environment name — the ONLY way the
        // version of an already-installed OS/7 can be known, because the release
        // manifest itself lives on the encrypted rpool while the BE name lives in
        // the unencrypted bpool (§4.2, D3). The parser and the writer are on
        // opposite sides of an install, so the round trip is checked against the
        // scheme §4.4 pins rather than against an example.
        foreach ((string be, string? want) in new (string, string?)[]
                 {
                     ("os7_1.0.0.32_202608241419", "1.0.0.32"),
                     ("os7_0.0.0.0_202601010000",  "0.0.0.0"),
                     ("os7_1.0.0.32_20260824",     null),   // stamp too short
                     ("os7_1.0.0.32_notadate12",   null),   // stamp not digits
                     ("ubuntu_1_202608241419",     null),   // not ours
                     ("os7_202608241419",          null),   // no release field
                     ("",                          null),
                 })
            Check(ExistingInstalls.VersionOf(be) == want,
                  $"boot environment '{be}' -> {want ?? "not an OS/7 name"}",
                  ExistingInstalls.VersionOf(be) ?? "null");

        // ---------------------------------------------------------------------
        // Screen 7's rules, checked HERE rather than left to `useradd`.
        //
        // useradd runs inside the chroot, six steps and several minutes after
        // the screen that could have said "that is not a valid user name" - and
        // by then the disk has been partitioned. These are the checks that keep
        // a typo from costing an install.
        foreach ((string name, bool ok) in new[]
                 {
                     ("os7", true), ("bastian", true), ("a_b-c9", true), ("_svc", true),
                     ("", false), ("Root", false), ("9lives", false), ("has space", false),
                     ("dot.ted", false), ("ünlaut", false), ("toolongtoolongtoolongtoolongtoolong", false),
                 })
            Check(AccountPlan.IsValidUsername(name) == ok,
                  $"user name '{name}' is {(ok ? "valid" : "refused")}");

        foreach ((string host, bool ok) in new[]
                 {
                     ("os7", true), ("build-01", true), ("a", true),
                     ("", false), ("-lead", false), ("trail-", false),
                     ("under_score", false), ("dot.ted", false),
                 })
            Check(AccountPlan.IsValidHostname(host) == ok,
                  $"computer name '{host}' is {(ok ? "valid" : "refused")}");

        // Reserved names get through the syntax check and must still be refused.
        var taken = new InstallPlan { Account = { Username = "root", Password = "longenough" } };
        var why3 = new List<string>();
        taken.Account.Validate(why3);
        Check(why3.Any(w => w.Contains("already uses")),
              "a name the system already uses is refused", string.Join("; ", why3));

        // And the account password must never reach the plan file, for the same
        // reason the disk passphrase must not (§6.6).
        var secret2 = new InstallPlan
        {
            Storage = { Disk = "/dev/disk/by-id/x" },
            Account = { Username = "os7", Password = "hunter2hunter2" },
        };
        Check(!secret2.ToJson().Contains("hunter2"),
              "the account password is not serialised into the plan");

        // The GUI/headless question is amd64's alone: arm64 ships no desktop, so
        // a screen offering the choice would offer something that is not there.
        Check(ModeScreen.Applies == (System.Runtime.InteropServices.RuntimeInformation
                  .OSArchitecture != System.Runtime.InteropServices.Architecture.Arm64),
              "screen 8 is offered only where there is a desktop to choose",
              ModeScreen.Applies ? "offered" : "skipped (arm64 is server-only)");

        Check(SystemLists.Languages.Length > 0, "languages", $"{SystemLists.Languages.Length}");
        Check(SystemLists.Keyboards.Length > 0, "keyboard layouts", $"{SystemLists.Keyboards.Length}");
        Check(SystemLists.Timezones.Length > 0, "timezones", $"{SystemLists.Timezones.Length}");

        // Rendering must not depend on a terminal existing. Every screen is
        // drawn into an off-screen frame at the reference geometry, which is
        // what makes the golden-frame tests in §6.5 possible at all.
        try
        {
            var p2 = new InstallPlan();
            var disk = new Disk("/dev/sdz", "/dev/disk/by-id/scsi-selftest", "sdz",
                                953_000_000_000L, "SELFTEST", "0", "gpt", 3, null,
                                Array.Empty<(string, string)>(), Os7Layout: false);
            Screen[] screens =
            {
                new WelcomeScreen(p2), new LicenceScreen(p2), new RegionalScreen(p2),
                new DiskScreen(p2), new LayoutScreen(p2, disk), new ConfirmScreen(p2, disk),
                new AccountScreen(p2), new ModeScreen(p2),
                new CompleteScreen(p2), ErrorScreen.ForCommand(
                    "Setup could not import the pool.",
                    "zpool import -f -N -R /target rpool",
                    "cannot import 'rpool': pool was previously in use from another system"),
            };
            foreach (Screen s in screens)
            {
                var f = new Frame(80, 25);
                s.Layout(80, 25);
                f.Chrome(s.Title, s.Status, Release.Current.TitleBar);
                s.Draw(f);
                string rendered = f.Render();
                Check(rendered.Length > 0, $"screen renders: {s.GetType().Name}",
                      $"{rendered.Length} bytes");
            }
        }
        catch (Exception ex)
        {
            Check(false, "screens render", ex.Message);
        }

        Console.Out.WriteLine($"SELFTEST-DONE failures={bad} image-files-absent={absent}");
        if (bad > 0 && bad == absent)
            Console.Out.WriteLine("SELFTEST-NOTE every failure is an image file that is "
                                  + "not there. Outside an OS/7 image that is expected; "
                                  + "inside one it is a broken build.");
        return bad == 0 ? 0 : 1;
    }

    private const string Usage = """
        Usage: os7-setup [options]

          --unattend <plan.json>     run from a plan file, without the UI
          --passphrase-file <path>   the disk passphrase (never in the plan file)
          --password-file <path>     the account password (never in the plan file)
          --storage-only             prepare the disk and stop; do not install a system
          --dry-run                  print every command instead of running it
          --geometry <cols>x<rows>   force the canvas size (SETUP-PLAN §2.4)
          --print-plan               write the install plan as JSON and exit
          --self-test                check fonts, palettes, lists and screens
          --version                  the OS/7 release on this medium
          --help                     this message

        Phase 3: from screen 10 onwards this WRITES TO A DISK, and the result
        boots.
        """;

    private readonly struct Options
    {
        public bool Help { get; init; }
        public bool Version { get; init; }
        public bool PrintPlan { get; init; }
        public bool SelfTest { get; init; }
        public bool DryRun { get; init; }
        public string? Geometry { get; init; }
        public string? Unattend { get; init; }
        public string? PassphraseFile { get; init; }
        public string? PasswordFile { get; init; }
        public bool StorageOnly { get; init; }
        public string? Error { get; init; }

        public static Options Parse(string[] args)
        {
            bool help = false, print = false, self = false, dryRun = false;
            bool version = false;
            string? geometry = null, unattend = null, passphraseFile = null;
            string? passwordFile = null;
            bool storageOnly = false;
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--help" or "-h": help = true; break;
                    case "--version" or "-V": version = true; break;
                    case "--print-plan": print = true; break;
                    case "--self-test": self = true; break;
                    case "--dry-run": dryRun = true; break;
                    case "--storage-only": storageOnly = true; break;
                    case "--password-file":
                        if (++i >= args.Length)
                            return new Options { Error = "--password-file needs a path" };
                        passwordFile = args[i];
                        break;
                    case "--unattend":
                        if (++i >= args.Length)
                            return new Options { Error = "--unattend needs a plan file" };
                        unattend = args[i];
                        break;
                    case "--passphrase-file":
                        if (++i >= args.Length)
                            return new Options { Error = "--passphrase-file needs a path" };
                        passphraseFile = args[i];
                        break;
                    case "--geometry":
                        if (++i >= args.Length)
                            return new Options { Error = "--geometry needs <cols>x<rows>" };
                        geometry = args[i];
                        break;
                    default:
                        return new Options { Error = $"unknown option '{args[i]}'" };
                }
            }
            if (passphraseFile is not null && unattend is null)
                return new Options { Error = "--passphrase-file only means something with --unattend" };
            if (passwordFile is not null && unattend is null)
                return new Options { Error = "--password-file only means something with --unattend" };
            return new Options
            {
                Help = help, Version = version, PrintPlan = print,
                SelfTest = self, Geometry = geometry,
                DryRun = dryRun, Unattend = unattend, PassphraseFile = passphraseFile,
                PasswordFile = passwordFile, StorageOnly = storageOnly,
            };
        }
    }
}
