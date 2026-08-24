using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Screens;
using OS7.Setup.Tui;

namespace OS7.Setup;

/// <summary>
/// os7-setup — OS/7's text-mode installer. installer/SETUP-PLAN.md is the design.
///
///     os7-setup                    run interactively on this terminal
///     os7-setup --print-plan       write the default plan as JSON and exit
///     os7-setup --self-test        check the things that fail silently, and exit
///     os7-setup --geometry 80x25   force the canvas size (§2.4)
///
/// PHASE 1, AND STRICTLY NON-DESTRUCTIVE. Nothing here opens a block device.
/// Screens 4-11 do not exist, so the flow is Welcome -> Licence -> Regional ->
/// Complete, and Complete says in as many words that no disk was touched.
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

        try
        {
            Geometry geometry = Geometry.FromCommandLine(options.Geometry);
            using Terminal terminal = Terminal.Acquire(geometry);
            var plan = new InstallPlan();
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

        Check(SystemLists.Languages.Length > 0, "languages", $"{SystemLists.Languages.Length}");
        Check(SystemLists.Keyboards.Length > 0, "keyboard layouts", $"{SystemLists.Keyboards.Length}");
        Check(SystemLists.Timezones.Length > 0, "timezones", $"{SystemLists.Timezones.Length}");

        // Rendering must not depend on a terminal existing. Every screen is
        // drawn into an off-screen frame at the reference geometry, which is
        // what makes the golden-frame tests in §6.5 possible at all.
        try
        {
            var p2 = new InstallPlan();
            Screen[] screens =
            {
                new WelcomeScreen(p2), new LicenceScreen(p2), new RegionalScreen(p2),
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

          --geometry <cols>x<rows>   force the canvas size (SETUP-PLAN §2.4)
          --print-plan               write the install plan as JSON and exit
          --self-test                check fonts, palettes, lists and screens
          --help                     this message

        Phase 1: strictly non-destructive. No disk is opened.
        """;

    private readonly struct Options
    {
        public bool Help { get; init; }
        public bool PrintPlan { get; init; }
        public bool SelfTest { get; init; }
        public string? Geometry { get; init; }
        public string? Error { get; init; }

        public static Options Parse(string[] args)
        {
            bool help = false, print = false, self = false;
            string? geometry = null;
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--help" or "-h": help = true; break;
                    case "--print-plan": print = true; break;
                    case "--self-test": self = true; break;
                    case "--geometry":
                        if (++i >= args.Length)
                            return new Options { Error = "--geometry needs <cols>x<rows>" };
                        geometry = args[i];
                        break;
                    default:
                        return new Options { Error = $"unknown option '{args[i]}'" };
                }
            }
            return new Options
            {
                Help = help, PrintPlan = print, SelfTest = self, Geometry = geometry,
            };
        }
    }
}
