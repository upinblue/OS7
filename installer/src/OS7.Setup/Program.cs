using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Screens;
using OS7.Setup.Steps;
using OS7.Setup.Tui;

namespace OS7.Setup;

/// <summary>
/// os7-setup — OS/7's text-mode installer. installer/SETUP-PLAN.md is the design.
///
///     os7-setup                          run interactively on this terminal
///     os7-setup --unattend plan.json     run it from a file, no UI (§6.6)
///     os7-setup --passphrase-file f      where the disk passphrase comes from
///     os7-setup --dry-run                print every command instead of running it
///     os7-setup --print-plan             write the default plan as JSON and exit
///     os7-setup --self-test              check what fails silently, and exit
///     os7-setup --geometry 80x25         force the canvas size (§2.4)
///
/// PHASE 2. The flow is Welcome -> Licence -> Regional -> Disk -> Layout ->
/// Confirm -> (execute) -> Complete, and from the Confirm screen onwards IT
/// WRITES TO A DISK. Screens 7-11 do not exist: no system is copied, no account
/// is created and no bootloader is installed, so the result does not boot and
/// Complete says so.
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

        Log.Info($"os7-setup starting ({string.Join(' ', args)})");

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

            if (!plan.Validate(out List<string> problems))
            {
                foreach (string p in problems) Console.Error.WriteLine($"os7-setup: {p}");
                Log.Error("unattended plan is not valid: " + string.Join("; ", problems));
                return 2;
            }

            Log.Info($"unattended{(o.DryRun ? " (dry run)" : "")}: {plan.ToJson().ReplaceLineEndings(" ")}");
            var executor = new Executor(o.DryRun);
            executor.Run(StorageSteps.For(plan),
                         (step, done, total) =>
                             Console.Out.WriteLine($"OS7-SETUP [{done}/{total}] {step}"));
            Console.Out.WriteLine("OS7-SETUP-DONE storage");
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
        int bad = 0;
        void Check(bool ok, string what, string detail = "")
        {
            Console.Out.WriteLine($"SELFTEST {(ok ? "ok  " : "FAIL")} {what}"
                                  + (detail.Length > 0 ? $" — {detail}" : ""));
            if (!ok) bad++;
        }

        List<string> conflicts = Input.PrefixConflicts();
        Check(conflicts.Count == 0, "key table unambiguous",
              conflicts.Count == 0 ? "" : string.Join("; ", conflicts));

        foreach (Palette p in new[] { Palette.Default, Palette.HighContrast })
            Check(File.Exists(Themes.PaletteFile(p)), $"palette {p}", Themes.PaletteFile(p));

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
            Check(File.Exists(f.Path) && f.Path.Contains(want) && cols >= 80 && rows >= 25,
                  $"console font for {w}x{h} is {want} -> {cols}x{rows}", f.Path);
        }

        Check(File.Exists(LicenceScreen.Path), "licence text", LicenceScreen.Path);

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
                                953_000_000_000L, "SELFTEST", "0", "gpt", 3, null);
            Screen[] screens =
            {
                new WelcomeScreen(p2), new LicenceScreen(p2), new RegionalScreen(p2),
                new DiskScreen(p2), new LayoutScreen(p2, disk), new ConfirmScreen(p2, disk),
                new CompleteScreen(p2), ErrorScreen.ForCommand(
                    "Setup could not import the pool.",
                    "zpool import -f -N -R /target rpool",
                    "cannot import 'rpool': pool was previously in use from another system"),
            };
            foreach (Screen s in screens)
            {
                var f = new Frame(80, 25);
                s.Layout(80, 25);
                f.Chrome(s.Title, s.Status);
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

        Console.Out.WriteLine($"SELFTEST-DONE failures={bad}");
        return bad == 0 ? 0 : 1;
    }

    private const string Usage = """
        Usage: os7-setup [options]

          --unattend <plan.json>     run from a plan file, without the UI
          --passphrase-file <path>   the disk passphrase (never in the plan file)
          --dry-run                  print every command instead of running it
          --geometry <cols>x<rows>   force the canvas size (SETUP-PLAN §2.4)
          --print-plan               write the install plan as JSON and exit
          --self-test                check fonts, palettes, lists and screens
          --help                     this message

        Phase 2: from the Confirm screen onwards this WRITES TO A DISK.
        """;

    private readonly struct Options
    {
        public bool Help { get; init; }
        public bool PrintPlan { get; init; }
        public bool SelfTest { get; init; }
        public bool DryRun { get; init; }
        public string? Geometry { get; init; }
        public string? Unattend { get; init; }
        public string? PassphraseFile { get; init; }
        public string? Error { get; init; }

        public static Options Parse(string[] args)
        {
            bool help = false, print = false, self = false, dryRun = false;
            string? geometry = null, unattend = null, passphraseFile = null;
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--help" or "-h": help = true; break;
                    case "--print-plan": print = true; break;
                    case "--self-test": self = true; break;
                    case "--dry-run": dryRun = true; break;
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
            return new Options
            {
                Help = help, PrintPlan = print, SelfTest = self, Geometry = geometry,
                DryRun = dryRun, Unattend = unattend, PassphraseFile = passphraseFile,
            };
        }
    }
}
