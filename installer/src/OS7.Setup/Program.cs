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
///     os7-setup --test-network p.json    apply the network HERE and report (3b)
///     os7-setup --geometry 80x25         force the canvas size (§2.4)
///
/// PHASE 3b. The flow is Welcome -> Licence -> Regional -> Disk -> Layout ->
/// Confirm -> Account -> Mode -> Network -> (install) -> Complete, with two
/// lettered screens hanging off Network: 9W for a wireless network and 9S for
/// static addresses. Screen 6 is the gate and screen 10 is where the writing
/// starts, so the disk is still untouched while the account and the network are
/// typed.
///
/// THE RESULT BOOTS. The system is copied, an account exists, the initramfs can
/// unlock and import, and the bootloader menu resolves a boot environment - each
/// of those checked by the step that did it, because "the installer said it
/// worked" is the class of evidence this project has been bitten by repeatedly.
///
/// AND IT IS REACHABLE. Screen 9 was added in Phase 3b because the shipped image
/// configures no network at all: empty /etc/netplan, no cloud-init, and
/// systemd-networkd not enabled - only networkd-dispatcher, which is its
/// consumer (L23, measured on both ISOs 2026-08-25). Every headless install
/// before it produced a machine nobody had chosen to make unreachable.
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
            // FOUR FIELDS HERE, not the friendly three the screens carry.
            // `--version` is somebody asking, and IDENTITY-PLAN §5.1 gives the
            // build number to everything that is asked rather than glanced at.
            Console.Out.WriteLine(r.DisplayFull);
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

        // The display rule, applied to versions handed in rather than to this
        // medium's own. It exists for ONE caller —
        // installer/testing/check-version-rule.py — and for one reason: the
        // rule in Model/Release.cs and the rule in Get-OS7Version are two
        // implementations of one specification, in two languages, and nothing
        // else in this repository can make them disagree loudly.
        //
        // TSV and not JSON deliberately: NativeAOT trims the reflection
        // serialiser away (spike S2), so JSON here would mean a second
        // source-generated context for four strings. `version:channel` in,
        // `version<TAB>channel<TAB>short<TAB>full` out, and the checker owns
        // the cases so there is no second copy of the table to drift.
        //
        // Before the log ring, like --version and --self-test: a diagnostic
        // that changes nothing must not create a file.
        if (options.VersionRule is { } cases)
        {
            foreach (string spec in cases)
            {
                int colon = spec.LastIndexOf(':');
                if (colon <= 0 || colon == spec.Length - 1)
                {
                    Console.Error.WriteLine(
                        $"os7-setup: --version-rule takes <version>:<channel>, got '{spec}'");
                    return 2;
                }
                Release r = Release.ForRule(spec[..colon], spec[(colon + 1)..]);
                Console.Out.WriteLine(
                    $"{r.Version}\t{r.Channel}\t{r.Short}\t{r.Full}");
            }
            return 0;
        }

        // A DIAGNOSTIC THAT CHANGES NOTHING. `--self-test` runs in the chroot
        // during the ISO build, so a log file opened here is a file baked into
        // the squashfs and shipped to every installed machine. Before the ring,
        // because Main's own first line would otherwise open it.
        if (options.SelfTest) Log.MemoryOnly();

        Log.Info($"os7-setup starting ({string.Join(' ', args)})");
        // The log is a support artefact, so it carries the build field.
        Log.Info($"release: {Release.Current.DisplayFull} "
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
        if (options.TestNetwork is not null) return TestNetwork(options);
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
                // LiveOnly: the length is the diagnostic for exactly the trap
                // the TrimEnd above avoids - a file one byte longer than the
                // secret in it - and it is also the one line here worth
                // redacting out of a log that lands on a disk that persists.
                Log.LiveOnly($"passphrase read from {o.PassphraseFile} "
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
                // LiveOnly, and here the disk it would land on is the one
                // carrying the /etc/shadow entry this password hashes into.
                Log.LiveOnly($"account password read from {o.PasswordFile} "
                             + $"({plan.Account.Password.Length} characters)");
            }
            if (o.WifiSecretFile is not null)
            {
                // A THIRD FILE, and the third instance of this rule (L25). The
                // Wi-Fi PSK and the 802.1X password are [JsonIgnore] in
                // WifiPlan for the same reason the other two secrets are: the
                // plan is a file that goes into `--print-plan`, a log, a
                // screendump and a repository.
                //
                // One file serves both because a network is either PSK or
                // 802.1X and never both, so which field it lands in is decided
                // by the plan rather than by the operator remembering.
                string secret = File.ReadAllText(o.WifiSecretFile).TrimEnd('\r', '\n');
                WifiPlan w = plan.Network.Wifi ??= new WifiPlan();
                if (w.Security == WifiSecurity.Enterprise) w.Password = secret;
                else w.Psk = secret;
                // LiveOnly for consistency rather than for effect: L25 already
                // puts this secret on the target IN PLAINTEXT, in the netplan
                // file, so its length is not what gives it away. The rule is
                // "a line about a secret is live-only", and a rule with an
                // exception in it is a rule nobody applies correctly later.
                Log.LiveOnly($"wireless secret read from {o.WifiSecretFile} "
                             + $"({secret.Length} characters, {w.Security})");
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
    /// `--test-network plan.json` — apply the network half of a plan HERE, on
    /// the live medium, and say what happened. Nothing is installed and no disk
    /// is touched.
    ///
    /// It exists for two audiences and neither is hypothetical:
    ///
    ///   the harness   `run-phase3b-network.py wifi` needs to prove an
    ///                 association without doing a twenty-minute install to get
    ///                 to it. Driving screen 9W through the framebuffer would
    ///                 prove the screen; this proves the code the screen calls,
    ///                 which is the half that talks to a radio.
    ///   a person      on tty2, in front of a machine whose network does not
    ///                 work, with Setup still on the screen behind them.
    ///
    /// It is the SAME `NetworkProbe.Test` that screen 9's F4 calls. A second
    /// implementation that agreed with the first today is exactly what §6.6's
    /// "one plan, one executor" exists to prevent.
    /// </summary>
    private static int TestNetwork(Options o)
    {
        try
        {
            InstallPlan? plan = InstallPlan.FromJson(File.ReadAllText(o.TestNetwork!));
            if (plan is null)
            {
                Console.Error.WriteLine($"os7-setup: {o.TestNetwork} is not an install plan");
                return 2;
            }
            if (o.WifiSecretFile is not null)
            {
                string secret = File.ReadAllText(o.WifiSecretFile).TrimEnd('\r', '\n');
                WifiPlan w = plan.Network.Wifi ??= new WifiPlan();
                if (w.Security == WifiSecurity.Enterprise) w.Password = secret;
                else w.Psk = secret;
            }

            // ONLY the network half is validated. The plan handed to this option
            // has no disk and no account in it, and demanding them would refuse
            // a plan that is complete for what it is being asked to do — the
            // same argument as `--storage-only`, and the same one that makes a
            // screen validate only what it collected.
            var problems = new List<string>();
            plan.Network.Validate(problems);
            if (problems.Count > 0)
            {
                foreach (string p in problems) Console.Error.WriteLine($"os7-setup: {p}");
                return 2;
            }

            (bool ok, string detail) = NetworkProbe.Test(plan);
            Console.Out.WriteLine($"OS7-NETWORK {(ok ? "OK" : "FAILED")} {detail}");
            return ok ? 0 : 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"OS7-NETWORK FAILED {ex.GetType().Name}: {ex.Message}");
            Log.Error($"--test-network: {ex}");
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

        // ---------------------------------------------------------------------
        // THE DISPLAY RULE (docs/IDENTITY-PLAN.md §5), checked here and again in
        // PowerShell by installer/testing/check-version-rule.py, which drives
        // `--version-rule` and Get-OS7Version over the same cases.
        //
        // It is asserted on both sides of the channel test and on both forms,
        // because the three ways this can go wrong are all silent: three fields
        // where four were meant loses the build number a support case needs;
        // four where three were meant puts a git commit count on a screen a
        // customer reads; and a channel that stops being printed turns a
        // development build into something that looks shipped.
        {
            Release dev = Release.ForRule("1.0.0.95", "development");
            Check(dev.Short == "1.0.0 (development)",
                  "the friendly version drops the build field", dev.Short);
            Check(dev.Full == "1.0.0.95 (development)",
                  "the full version keeps it", dev.Full);
            Check(dev.TitleBar == "Version 1.0.0 (development)",
                  "the title row is the friendly form", dev.TitleBar);
            Check(dev.DisplayFull == "OS/7 1.0.0.95 (development)",
                  "--version and the Welcome screen are the full form", dev.DisplayFull);

            Release rel = Release.ForRule("2.1.4.1207", "stable");
            Check(rel.Short == "2.1.4" && rel.Full == "2.1.4.1207",
                  "a stable release names no channel", $"{rel.Short} / {rel.Full}");

            // A short version must come back unchanged, not padded and not
            // truncated to something that looks like a different release.
            Release odd = Release.ForRule("1.0", "stable");
            Check(odd.Short == "1.0" && odd.Full == "1.0",
                  "a version with fewer than four fields survives", odd.Short);

            // The invariant the two forms exist to keep: one is a prefix of the
            // other. If this ever fails, two screens are naming two releases.
            Check(Release.Current.Full.StartsWith(Release.Current.FriendlyVersion)
                  || !Release.Current.Known,
                  "this medium's two forms name the same release",
                  $"{Release.Current.Short} / {Release.Current.Full}");
        }

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
            int box = Frame.BoxWidthFor(cols);
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

            // §3.1 draws the box at columns 5..76. Screens position content from
            // its LEFT edge, so this is the check that its right edge is where
            // the mockup puts it, and that the rows are sized to what is inside.
            var geometry = new Frame(cols, 25);
            Check(box == 72 && room == 68 && geometry.Left + 5 == 5
                  && geometry.Left + 5 + box - 1 == 76,
                  "screen 4's box spans columns 5..76 and gives a row 68",
                  $"box {box} at {geometry.Left + 5}..{geometry.Left + 5 + box - 1}, row {room}");

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

        // ---------------------------------------------------------------------
        // THE GATES, WALKED. Screen 6 -> screen 7, and the door in front of the
        // executor.
        //
        // This exists because the flow was broken for a whole commit and every
        // check in the repository still passed. `--unattend` hands over a plan
        // with an account already in it, `--storage-only` skips the account
        // check by design, and the one harness that drove the screens by hand
        // had not been taught that Phase 3 inserted screens 7 and 8 — so
        // "os7-setup cannot get past screen 6" was invisible from three
        // directions at once.
        //
        // It is two `Handle` calls on screens built off a terminal, which is
        // exactly what §6.5 says screens are for. It runs in the chroot during
        // the ISO build (hook 0080), so a flow that cannot reach screen 7 fails
        // the BUILD rather than the VM.
        //
        // WHAT IS NOT CHECKED HERE, and must not be: the far side of screen 7.
        // A complete plan through `ExecuteScreen.Start` returns an executor, and
        // an executor is a thread partitioning a disk. The self-test runs as
        // root inside a build chroot. Only the refusal is safe to ask for, and
        // the refusal is the half that guards a person.
        {
            // Everything screens 3, 4 and 5 collect, and not a field more —
            // which is precisely the state the plan is in when `F` is pressed.
            var atScreen6 = new InstallPlan
            {
                Storage = { Disk = "/dev/disk/by-id/scsi-selftest",
                            Encrypt = true, Passphrase = "correct horse battery" },
            };
            var target = new Disk("/dev/sdz", "/dev/disk/by-id/scsi-selftest", "sdz",
                                  953_000_000_000L, "SELFTEST", "0", "gpt", 3, null,
                                  Array.Empty<(string, string)>(), Os7Layout: false);

            Check(atScreen6.ValidateThroughStorage(out List<string> why4),
                  "screen 6's check passes a plan that has no account yet",
                  string.Join("; ", why4));
            Check(!atScreen6.Validate(out List<string> why5)
                  && why5.Any(w => w.Contains("account")),
                  "and the whole-plan check still refuses the same plan",
                  string.Join("; ", why5));

            // The transition itself, not the predicate behind it: the bug was a
            // screen calling the wrong check, so asking the check is asking the
            // wrong question. Press F and see which screen comes back.
            Transition t = new ConfirmScreen(atScreen6, target)
                .Handle(new KeyPress(Key.Char, 'F', "F"));
            Check(t.Kind == TransitionKind.Goto && t.Next is AccountScreen,
                  "F on screen 6 reaches screen 7 with no account in the plan",
                  t.Next?.GetType().Name ?? t.Kind.ToString());

            // And the check that moved: the same plan must not be able to open
            // the executor. `Start` refuses before the constructor runs, so
            // nothing is written and there is no thread to join.
            Screen refusedByGate = ExecuteScreen.Start(atScreen6);
            Check(refusedByGate is ErrorScreen,
                  "the executor's own gate refuses a plan with no account",
                  refusedByGate.GetType().Name);
        }

        // The GUI/headless question is amd64's alone: arm64 ships no desktop, so
        // a screen offering the choice would offer something that is not there.
        Check(ModeScreen.Applies == (System.Runtime.InteropServices.RuntimeInformation
                  .OSArchitecture != System.Runtime.InteropServices.Architecture.Arm64),
              "screen 8 is offered only where there is a desktop to choose",
              ModeScreen.Applies ? "offered" : "skipped (arm64 is server-only)");

        Check(SystemLists.Languages.Length > 0, "languages", $"{SystemLists.Languages.Length}");
        Check(SystemLists.Keyboards.Length > 0, "keyboard layouts", $"{SystemLists.Keyboards.Length}");
        Check(SystemLists.Timezones.Length > 0, "timezones", $"{SystemLists.Timezones.Length}");

        // -------------------------------------------------------------------
        // THE NETPLAN GENERATOR, CHECKED WITHOUT A NETWORK.
        //
        // `NetworkPlan.ToNetplanYaml` is a pure function of the plan, and that
        // is what makes this possible at all: hook 0080 runs --self-test inside
        // the chroot during the ISO build, so a generator that stops producing
        // `dhcp4:` fails the BUILD rather than an install an hour later. A
        // generator whose first test is an install is a generator tested once.
        // -------------------------------------------------------------------
        {
            const string V = "selftest";

            var dhcp = new NetworkPlan
            {
                Interface = "enp1s0", Kind = LinkKind.Wired, Method = NetworkMethod.Dhcp,
            };
            string y = dhcp.ToNetplanYaml("networkd", V);
            Check(y.Contains("renderer: networkd") && y.Contains("  ethernets:")
                  && y.Contains("    enp1s0:") && y.Contains("dhcp4: true"),
                  "netplan: DHCP over Ethernet");

            // L30, AND THE MOST EXPENSIVE THING THIS PHASE LEARNED. An interface
            // name is not stable across the install: the setup medium is a PCI
            // device, so removing it renumbers the slots that predictable names
            // come from. Measured 2026-08-25 - enp0s5 while installing, enp0s2
            // once booted, one machine, one NIC. A netplan file naming the
            // install-time name matches nothing afterwards, and netplan accepts
            // that silently: no address, no route, no error.
            var byMac = new NetworkPlan
            {
                Interface = "enp0s5", MacAddress = "52:54:00:12:34:56",
                Kind = LinkKind.Wired, Method = NetworkMethod.Dhcp,
            };
            y = byMac.ToNetplanYaml("networkd", V);
            Check(y.Contains("match:") && y.Contains("macaddress: \"52:54:00:12:34:56\"")
                  && y.Contains("    os7net:") && !y.Contains("enp0s5"),
                  "netplan: a chosen adapter is matched by MAC, never by name");

            var stat = new NetworkPlan
            {
                Interface = "enp1s0", Kind = LinkKind.Wired, Method = NetworkMethod.Static,
                Address = "10.0.2.99/24", Gateway = "10.0.2.2",
                Nameservers = new List<string> { "10.0.2.3" },
                Search = new List<string> { "corp.example.com" },
            };
            y = stat.ToNetplanYaml("networkd", V);
            Check(y.Contains("dhcp4: false") && y.Contains("- 10.0.2.99/24")
                  && y.Contains("- to: default") && y.Contains("via: 10.0.2.2")
                  && y.Contains("          - 10.0.2.3"),
                  "netplan: static address, gateway and DNS");
            // `gateway4:` is deprecated and netplan warns about it — into a log
            // nobody on a headless machine reads. The route form is the one that
            // does not rot.
            Check(!y.Contains("gateway4"), "netplan: no deprecated gateway4 key");

            var psk = new NetworkPlan
            {
                Interface = "wlp2s0", Kind = LinkKind.Wireless, Method = NetworkMethod.Dhcp,
                Wifi = new WifiPlan { Ssid = "Branch-Office", Psk = "hunter2hunter2" },
            };
            y = psk.ToNetplanYaml("networkd", V);
            Check(y.Contains("  wifis:") && y.Contains("access-points:")
                  && y.Contains("\"Branch-Office\":") && y.Contains("key-management: psk")
                  && y.Contains("password: \"hunter2hunter2\""),
                  "netplan: WPA2 personal");

            var eap = new NetworkPlan
            {
                Interface = "wlp2s0", Kind = LinkKind.Wireless, Method = NetworkMethod.Dhcp,
                Wifi = new WifiPlan
                {
                    Ssid = "CORP-SECURE", Security = WifiSecurity.Enterprise,
                    Identity = "user@corp.example.com", Password = "s3cret",
                    CaCertificate = "/run/media/ca.pem",
                },
            };
            y = eap.ToNetplanYaml("networkd", V);
            Check(y.Contains("key-management: eap") && y.Contains("method: peap")
                  && y.Contains("phase2-auth: MSCHAPV2")
                  && y.Contains("identity: \"user@corp.example.com\"")
                  && y.Contains("ca-certificate: \"/run/media/ca.pem\""),
                  "netplan: 802.1X PEAP/MSCHAPv2");

            // An SSID is arbitrary bytes. A colon, a `#`, a leading `-` or a
            // quote each change what an unquoted YAML line means, and the result
            // is a file netplan either misreads or refuses.
            var odd = new NetworkPlan
            {
                Interface = "wlp2s0", Kind = LinkKind.Wireless, Method = NetworkMethod.Dhcp,
                Wifi = new WifiPlan { Ssid = "we: \"guest\" #1", Psk = "passphrase" },
            };
            y = odd.ToNetplanYaml("networkd", V);
            Check(y.Contains("\"we: \\\"guest\\\" #1\":"),
                  "netplan: an SSID with quotes and a colon is escaped");

            // L28: a plan replayed on another machine must not carry this
            // machine's interface name.
            var auto = new NetworkPlan
            {
                Interface = "auto", Kind = LinkKind.Wired, Method = NetworkMethod.Dhcp,
            };
            y = auto.ToNetplanYaml("networkd", V);
            Check(y.Contains("match:") && y.Contains("name: \"en*\""),
                  "netplan: interface 'auto' becomes a match glob");

            // The MAC wins over the glob when both could apply: `auto` is for a
            // plan replayed on a machine whose hardware Setup has never seen, so
            // a plan that DOES carry a MAC is describing a specific port.
            var both = new NetworkPlan
            {
                Interface = "auto", MacAddress = "aa:bb:cc:dd:ee:ff",
                Kind = LinkKind.Wired, Method = NetworkMethod.Dhcp,
            };
            y = both.ToNetplanYaml("networkd", V);
            Check(y.Contains("macaddress:") && !y.Contains("name: \"en*\""),
                  "netplan: a MAC in the plan beats the 'auto' glob");

            // Method.None writes NOTHING. The guard is here because a caller
            // that forgets is a caller that writes an empty `ethernets:` block,
            // which netplan accepts and which configures nothing.
            bool threw = false;
            try { new NetworkPlan { Method = NetworkMethod.None }.ToNetplanYaml("networkd", V); }
            catch (InvalidOperationException) { threw = true; }
            Check(threw, "netplan: Method.None refuses to render a file");

            // D14. The renderer is a function of screen 8's answer and of
            // nothing else, and L24 is what getting it wrong costs.
            Check(new InstallPlan { Mode = InstallMode.Gui }.Renderer == "NetworkManager"
                  && new InstallPlan { Mode = InstallMode.Headless }.Renderer == "networkd",
                  "netplan: renderer follows the install mode");

            // L25, AND IT IS THE ONE CHECK HERE THAT PROTECTS A SECRET RATHER
            // THAN A CONFIGURATION.
            //
            // `--print-plan` writes this JSON to a terminal, `Log.Info` writes
            // it into /var/log at the end of every install, and CompleteScreen
            // logs it while it is on screen. A `[JsonIgnore]` that was removed
            // in a refactor has NO symptom: the plan keeps working, the install
            // keeps working, and a Wi-Fi passphrase is in a log file and in a
            // screendump. So the guarantee is asserted against the serialiser's
            // real output, and it covers all three secrets rather than the one
            // this phase added.
            var secretive = new InstallPlan
            {
                Storage = { Passphrase = "LUKS-SECRET-CANARY" },
                Account = { Username = "u", Password = "ACCOUNT-SECRET-CANARY" },
                Network =
                {
                    Interface = "wlan0", Kind = LinkKind.Wireless,
                    Wifi = new WifiPlan
                    {
                        Ssid = "net", Psk = "PSK-SECRET-CANARY",
                        Password = "EAP-SECRET-CANARY",
                    },
                },
            };
            string serialised = secretive.ToJson();
            string[] canaries =
                { "LUKS-SECRET-CANARY", "ACCOUNT-SECRET-CANARY",
                  "PSK-SECRET-CANARY", "EAP-SECRET-CANARY" };
            string[] leaked = canaries.Where(serialised.Contains).ToArray();
            Check(leaked.Length == 0,
                  "no secret reaches the plan file (L25 and §6.6)",
                  leaked.Length == 0 ? "4 canaries, none serialised"
                                     : "LEAKED: " + string.Join(", ", leaked));

            Check(NetworkPlan.IsValidCidr("10.0.2.99/24")
                  && NetworkPlan.IsValidCidr("2001:db8::1/64")
                  && !NetworkPlan.IsValidCidr("10.0.2.99")
                  && !NetworkPlan.IsValidCidr("10.0.2.99/33")
                  && !NetworkPlan.IsValidCidr("not-an-address/24"),
                  "netplan: an address must carry a prefix length");

            // L24, ASSERTED RATHER THAN COMMENTED. The network step has to run
            // after the mode step, because the headless purge removes the
            // backend a NetworkManager-rendered file would name. A refactor that
            // reorders this list has no other symptom than a machine that comes
            // up with no network.
            var order = SystemSteps.For(new InstallPlan(), new TargetRoot("/target"));
            int mode = order.FindIndex(s => s is InstallModeStep);
            int net = order.FindIndex(s => s is NetworkStep);
            Check(mode >= 0 && net > mode,
                  "step order: the network is written after the desktop purge",
                  $"mode at {mode}, network at {net}");

            // L31, ASSERTED THE SAME WAY. The log copy has to run after the
            // steps whose proofs are worth keeping and before the pools are
            // exported, and both halves are position in one list. Moving it
            // after TeardownStep would write to a path that is no longer a
            // mounted filesystem, and `TargetRoot.Write` would create the
            // directory on the LIVE root instead - a file that looks right,
            // written to the disk that is about to be discarded.
            int boot = order.FindIndex(s => s is BootloaderStep);
            int keep = order.FindIndex(s => s is InstallLogStep);
            int down = order.FindIndex(s => s is TeardownStep);
            Check(boot >= 0 && keep > boot && down > keep,
                  "step order: the log is saved after the bootloader, before the export",
                  $"bootloader at {boot}, log at {keep}, teardown at {down}");

            // THE REDACTION, CHECKED AGAINST THE THING IT CLAIMS TO CHECK.
            // `Log.LiveOnly` is a promise about a file on somebody's disk, and
            // the only way to test a promise about text is to read the text.
            // Both directions: the marked line is absent from the persistent
            // transcript AND present in the volatile one, because a redactor
            // that empties the log passes the first check on its own.
            const string Canary = "passphrase set (SELFTEST-CANARY characters)";
            Log.LiveOnly(Canary);
            string kept = Log.Transcript(persistent: true);
            string live = Log.Transcript(persistent: false);
            Check(!kept.Contains("SELFTEST-CANARY") && kept.Contains("[not kept]"),
                  "log: a live-only line is redacted out of the installation record",
                  $"{kept.Length} bytes written to the target");
            Check(live.Contains(Canary),
                  "log: the same line is intact in the live log",
                  "the error screen and F2 still see it");

            // THE TRANSCRIPT IS COMPLETE, not a tail. This is the regression
            // guard for the bug that was in here until 2026-08-25: the log was a
            // 200-entry ring, an install logs 284 lines in a DRY run, and the
            // copy would have reached the target with the whole storage phase
            // and the start of AccountStep missing — a file that looks like a
            // record and is not one. 400 lines is past any ring anybody would
            // reintroduce; the marker is the FIRST of them.
            const string First = "SELFTEST-FIRST-OF-MANY";
            Log.Info(First);
            for (int i = 0; i < 400; i++) Log.Info($"selftest filler {i}");
            Check(Log.Transcript(persistent: true).Contains(First),
                  "log: the transcript keeps the first line after 400 more",
                  "the installation record is the whole log, not its tail");

            // And an ordinary line survives BOTH, which is the check that stops
            // "redact everything" from passing the two above.
            const string Ordinary = "SELFTEST-ORDINARY-LINE";
            Log.Info(Ordinary);
            Check(Log.Transcript(persistent: true).Contains(Ordinary)
                  && Log.Transcript(persistent: false).Contains(Ordinary),
                  "log: an ordinary line is in both transcripts",
                  "redaction is by mark, not by pattern");

            // The scan parser, against a captured `iw scan` rather than against
            // a radio. Strongest BSS wins, 802.1X beats PSK on a network that
            // advertises both, and a NUL-padded hidden SSID is not offered as a
            // network anybody can select.
            const string Captured = """
                BSS aa:bb:cc:dd:ee:01(on wlan0)
                	signal: -70.00 dBm
                	SSID: CORP-GUEST
                	RSN:	 * Version: 1
                		 * Authentication suites: PSK
                BSS aa:bb:cc:dd:ee:02(on wlan0)
                	signal: -42.00 dBm
                	SSID: CORP-GUEST
                	RSN:	 * Version: 1
                		 * Authentication suites: PSK
                BSS aa:bb:cc:dd:ee:03(on wlan0)
                	signal: -55.00 dBm
                	SSID: CORP-SECURE
                	RSN:	 * Version: 1
                		 * Authentication suites: IEEE 802.1X
                BSS aa:bb:cc:dd:ee:04(on wlan0)
                	signal: -80.00 dBm
                	SSID: \x00\x00\x00
                """;
            List<WifiNetwork> scan = WifiScan.Parse(Captured);
            WifiNetwork? guest = scan.FirstOrDefault(n => n.Ssid == "CORP-GUEST");
            WifiNetwork? secure = scan.FirstOrDefault(n => n.Ssid == "CORP-SECURE");
            Check(guest is not null && guest.SignalDbm == -42
                  && guest.Security == WifiSecurity.Psk,
                  "iw scan: the strongest BSS of a network wins",
                  guest is null ? "not found" : $"{guest.SignalDbm} dBm");
            Check(secure is not null && secure.Security == WifiSecurity.Enterprise,
                  "iw scan: 802.1X is recognised as enterprise");
            Check(scan.Count == 2,
                  "iw scan: four BSSes become two networks, the hidden one dropped",
                  $"{scan.Count}");

            // A link-local or an autoconfiguration address is an address and is
            // not a working network. Counting them would make the live test pass
            // on exactly the failure it exists to catch.
            Check(NetworkProbe.FirstGlobal(
                      "2: enp1s0    inet6 fe80::1/64 scope link \\       valid_lft forever")
                  is null,
                  "live test: a link-local address does not count as connected");
            Check(NetworkProbe.FirstGlobal(
                      "2: enp1s0    inet 169.254.7.7/16 scope global \\  valid_lft forever")
                  is null,
                  "live test: an autoconfiguration address does not count");
            Check(NetworkProbe.FirstGlobal(
                      "2: enp1s0    inet 10.0.2.15/24 scope global dynamic enp1s0")
                  == "10.0.2.15/24",
                  "live test: a global address is reported with its prefix");
        }

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
                // Screens 9, 9S and 9W. NetworkScreen enumerates adapters and
                // WifiScreen scans, and BOTH have to render on a machine that
                // has neither — this runs in the chroot during the ISO build,
                // where there is no radio and `iw` may not exist. A screen that
                // throws on an empty list is a screen that throws on an
                // air-gapped appliance.
                new NetworkScreen(p2), new StaticScreen(p2), new WifiScreen(p2),
                new CompleteScreen(p2), ErrorScreen.ForCommand(
                    "Setup could not import the pool.",
                    "zpool import -f -N -R /target rpool",
                    "cannot import 'rpool': pool was previously in use from another system"),
            };
            // WHERE THE BOX ENDS, on every screen that draws one, read out of
            // the cell buffer. §3.1 draws it at columns 5..76 and nine screens
            // draw it; they used to do so from nine copies of the same literal,
            // and a screen that quietly kept the old one would look right on its
            // own and wrong beside the screen before it. ExecuteScreen's
            // progress bar is §3.1's one deliberately narrower box and is not in
            // this list.
            (int Left, int Right)? BoxEdges(Frame f)
            {
                for (int r = 0; r < f.Rows; r++)
                    for (int c = 0; c < f.Cols; c++)
                        if (f[r, c].Rune == '┌')
                        {
                            for (int c2 = c + 1; c2 < f.Cols; c2++)
                                if (f[r, c2].Rune == '┐') return (c, c2);
                            return (c, -1);
                        }
                return null;
            }

            foreach (Screen s in screens)
            {
                var f = new Frame(80, 25);
                s.Layout(80, 25);

                // A TICKING SCREEN GETS ITS TICK. SetupFlow passes Key.None
                // through to any screen that opted in with `Ticks`, and for
                // WifiScreen that tick IS the scan — so without it this would
                // only ever render the "scanning…" frame and the box check
                // below would silently find no box to measure. Driving it here
                // exercises the idle-tick path of every screen that has one,
                // which is a path nothing else in --self-test touches.
                if (s.Ticks) s.Handle(KeyPress.None);

                f.Chrome(s.Title, s.Status, Release.Current.TitleBar);
                s.Draw(f);
                string rendered = f.Render();
                (int Left, int Right)? edges = BoxEdges(f);
                if (edges is { } e)
                    Check(e.Left == 5 && e.Right == 76,
                          $"{s.GetType().Name}'s box spans columns 5..76",
                          $"{e.Left}..{e.Right}");
                Check(rendered.Length > 0, $"screen renders: {s.GetType().Name}",
                      $"{rendered.Length} bytes");
            }

            // WHICH ROW A SETTINGS SCREEN ARRIVES ON — the fact that decides
            // whether the ENTER its own status bar names continues or opens a
            // picker.
            //
            // Screen 3 arrived on Language, where ENTER opens the language
            // picker and ESC returns to the same row, so the key the screen
            // asks for was a loop; the way out was three DOWNs nothing on the
            // screen mentions. Every VM harness that walks screen 3 carried
            // those three DOWNs as a literal, so all of them stayed green and
            // the only thing that could see it was a person driving the screen
            // by hand. docs/BUILD-NOTES.md #77.
            //
            // Checked HERE, and not only in a harness, because it costs no VM
            // and no ISO: the answer is in the cells of a frame that is already
            // being rendered, so hook 0080 asks it during the build.
            foreach (Screen s in new Screen[]
                     { new RegionalScreen(new InstallPlan()),
                       new LayoutScreen(new InstallPlan(), disk) })
            {
                var f = new Frame(80, 25);
                s.Layout(80, 25);
                f.Chrome(s.Title, s.Status, Release.Current.TitleBar);
                s.Draw(f);
                Check(AcceptRowIsSelected(f),
                      $"{s.GetType().Name} arrives on the accept row, so ENTER continues",
                      s.Status);
            }

            // The selection is drawn black on grey and spans the row
            // (Screen.Row), so the question is what the accept row's cells are
            // wearing. Ordinal and case-sensitive on purpose: the body line
            // "If all the settings are correct, press ENTER." is a different
            // string and must not answer for the row inside the box.
            static bool AcceptRowIsSelected(Frame f)
            {
                const string Accept = "The settings are correct.";
                var chars = new char[f.Cols];
                for (int r = 0; r < f.Rows; r++)
                {
                    for (int c = 0; c < f.Cols; c++) chars[c] = f[r, c].Rune;
                    if (!new string(chars).Contains(Accept, StringComparison.Ordinal))
                        continue;
                    for (int c = 0; c < f.Cols; c++)
                        if (f[r, c].Bg == Slot.Grey && f[r, c].Fg == Slot.Black)
                            return true;
                    return false;
                }
                return false;   // the row is not on the screen at all
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
          --wifi-secret-file <path>  the Wi-Fi PSK or 802.1X password (ditto)
          --test-network <plan.json> apply the network here and report; install nothing
          --storage-only             prepare the disk and stop; do not install a system
          --dry-run                  print every command instead of running it
          --geometry <cols>x<rows>   force the canvas size (SETUP-PLAN §2.4)
          --print-plan               write the install plan as JSON and exit
          --self-test                check fonts, palettes, lists and screens
          --version                  the OS/7 release on this medium
          --version-rule <v>:<ch> …  apply the display rule to versions given
                                     here and print them; for the cross-language
                                     check, not for humans
          --help                     this message

        Phase 3: from screen 10 onwards this WRITES TO A DISK, and the result
        boots.
        """;

    private readonly struct Options
    {
        public bool Help { get; init; }
        public bool Version { get; init; }

        /// <summary>
        /// `--version-rule <v>:<ch> …` — every remaining argument, for the
        /// cross-language check. Null when the flag was not given; an EMPTY
        /// array is a legitimate "apply the rule to nothing", so this cannot be
        /// collapsed into a bool plus a list.
        /// </summary>
        public string[]? VersionRule { get; init; }
        public bool PrintPlan { get; init; }
        public bool SelfTest { get; init; }
        public bool DryRun { get; init; }
        public string? Geometry { get; init; }
        public string? Unattend { get; init; }
        public string? PassphraseFile { get; init; }
        public string? PasswordFile { get; init; }
        public string? WifiSecretFile { get; init; }
        public string? TestNetwork { get; init; }
        public bool StorageOnly { get; init; }
        public string? Error { get; init; }

        public static Options Parse(string[] args)
        {
            bool help = false, print = false, self = false, dryRun = false;
            bool version = false;
            string[]? versionRule = null;
            string? geometry = null, unattend = null, passphraseFile = null;
            string? passwordFile = null, wifiSecretFile = null, testNetwork = null;
            bool storageOnly = false;
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--help" or "-h": help = true; break;
                    case "--version" or "-V": version = true; break;
                    // Everything after it, because the cases are a LIST and a
                    // list terminated by the end of the command line cannot be
                    // half-consumed by a later flag.
                    case "--version-rule":
                        versionRule = args[(i + 1)..];
                        i = args.Length;
                        break;
                    case "--print-plan": print = true; break;
                    case "--self-test": self = true; break;
                    case "--dry-run": dryRun = true; break;
                    case "--storage-only": storageOnly = true; break;
                    case "--password-file":
                        if (++i >= args.Length)
                            return new Options { Error = "--password-file needs a path" };
                        passwordFile = args[i];
                        break;
                    case "--test-network":
                        if (++i >= args.Length)
                            return new Options { Error = "--test-network needs a plan file" };
                        testNetwork = args[i];
                        break;
                    case "--wifi-secret-file":
                        if (++i >= args.Length)
                            return new Options { Error = "--wifi-secret-file needs a path" };
                        wifiSecretFile = args[i];
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
            if (wifiSecretFile is not null && unattend is null && testNetwork is null)
                return new Options { Error = "--wifi-secret-file needs --unattend or --test-network" };
            return new Options
            {
                Help = help, Version = version, VersionRule = versionRule,
                PrintPlan = print,
                SelfTest = self, Geometry = geometry,
                DryRun = dryRun, Unattend = unattend, PassphraseFile = passphraseFile,
                PasswordFile = passwordFile, WifiSecretFile = wifiSecretFile,
                TestNetwork = testNetwork,
                StorageOnly = storageOnly,
            };
        }
    }
}
