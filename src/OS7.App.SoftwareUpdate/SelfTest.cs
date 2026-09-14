using OS7.App.SoftwareUpdate.Model;
using OS7.App.SoftwareUpdate.Services;
using OS7.App.SoftwareUpdate.ViewModels;

namespace OS7.App.SoftwareUpdate;

/// <summary>
/// Every decision this application makes, asked without a machine, a
/// repository, a display or a PowerShell.
/// </summary>
/// <remarks>
/// <para>
/// The precedent is <c>os7-setup --self-test</c>, which runs inside the ISO
/// build so that a missing font fails a build rather than a boot.
/// <c>installer/testing/check-gui-logic.py</c> drives this.
/// </para>
/// <para>
/// WHAT IT DOES NOT CHECK: anything about how the window LOOKS. No window is
/// constructed here and none could be — the container has no display. O-G1 is
/// owed and this file does not narrow it by one pixel.
/// </para>
/// </remarks>
public static class SelfTest
{
	private static int _pass;
	private static readonly List<string> Failures = new();

	public static int Run()
	{
		Console.Error.WriteLine("OS/7 Software Update self-test");

		Rows();
		ReasonOrder();
		Window();
		Ordering();
		Sizes();
		UnitNames();

		Console.Error.WriteLine();
		Console.Error.WriteLine(
			$"  {_pass} ok, {Failures.Count} failed");

		foreach (var failure in Failures)
		{
			Console.Error.WriteLine($"    FAILED: {failure}");
		}

		return Failures.Count == 0 ? 0 : 1;
	}

	// ---------------------------------------------------------------- rows

	private static void Rows()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  A row reads the cmdlet's flags and never recomputes them");

		var available = Row(Release("1.0.0.204", applicable: true, newer: true));
		Check("an applicable release is installable", available.IsInstallable);
		Check("and says so in one word", available.Status == "Available.");

		var foreign = Row(Release("1.0.0.204", newer: true, foreignArch: true, arch: "arm64"));
		Check("a foreign-architecture release is not installable", !foreign.IsInstallable);
		Check("and the sentence names the architecture",
			foreign.Status.Contains("arm64", StringComparison.Ordinal));

		var major = Row(Release("2.0.0.1", newer: true, crossesMajor: true));
		Check("a release across a major is not installable", !major.IsInstallable);
		Check("and is called an installation rather than an update",
			major.Status.Contains("installation", StringComparison.OrdinalIgnoreCase));

		var older = Row(Release("1.0.0.100", newer: false));
		Check("a release that is not newer is not installable", !older.IsInstallable);

		// Newer, same major, this architecture, and still not applicable: by
		// elimination the hotfix base is what is in the way.
		var hotfix = Row(Release("1.0.0.205", newer: true, hotfix: true, hotfixBase: "1.0.0.204"));
		Check("a hotfix for another base is not installable", !hotfix.IsInstallable);
		Check("and the sentence names the base to get to first",
			hotfix.Status.Contains("1.0.0.204", StringComparison.Ordinal));

		var onBase = Row(Release("1.0.0.205", applicable: true, newer: true,
			hotfix: true, hotfixBase: "1.0.0.204"));
		Check("a hotfix ON its base IS installable", onBase.IsInstallable);
		Check("and still says it is a hotfix",
			onBase.Status.Contains("Hotfix", StringComparison.Ordinal));

		// THE ONE THAT IS EASY TO GET WRONG. Development is not part of the
		// cmdlet's Applicable; Update-OS7 refuses it separately.
		var dev = Row(Release("1.0.0.206", applicable: true, newer: true,
			development: true, signingKey: "(the descriptor names no key)"));
		Check("an APPLICABLE development release is still not installable here",
			!dev.IsInstallable);
		Check("and the sentence names -AllowDevelopment",
			dev.Status.Contains("-AllowDevelopment", StringComparison.Ordinal));
		Check("and carries the version, so the command can be typed as shown",
			dev.Status.Contains("1.0.0.206", StringComparison.Ordinal));

		var refused = Row(Release("1.0.0.100", newer: false));
		refused.IsSelected = true;
		Check("a row that cannot be installed refuses to be selected", !refused.IsSelected);
	}

	private static void ReasonOrder()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  When several reasons apply, one sentence wins, in order");

		var both = Row(Release("2.0.0.1", newer: true, crossesMajor: true,
			foreignArch: true, arch: "arm64"));
		Check("architecture outranks the major version",
			both.Block == ReleaseBlock.ForeignArchitecture);

		var majorAndOld = Row(Release("2.0.0.1", newer: false, crossesMajor: true));
		Check("the major version outranks not-newer",
			majorAndOld.Block == ReleaseBlock.CrossesMajor);
	}

	// -------------------------------------------------------------- window

	private static void Window()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  The window says four different things, not two");

		var empty = new MainWindowViewModel(Array.Empty<Os7Release>());
		Check("an empty channel is 'up to date'",
			empty.Header == "Your software is up to date.");
		Check("and no restart notice is shown", !empty.ShowRestartNotice);
		Check("and the button does not count anything",
			empty.InstallButtonText == "Install");
		Check("and nothing can be installed", !empty.CanInstall);

		// FOUND ON A MACHINE. A bench pointed at a development-signed repository
		// was offered 1.0.0.164 against its own 1.0.0.163 — newer, and blocked
		// here because it is not signed for production. The header keyed on
		// "installable" alone said "Your software is up to date" with that
		// release listed directly beneath it.
		var blockedButNewer = new MainWindowViewModel(new[]
		{
			Release("2.0.0.1", newer: true, crossesMajor: true),
		});
		Check("something NEWER that cannot be installed is not 'up to date'",
			blockedButNewer.Header
				== "New software exists, but none of it can be installed on this computer.");
		Check("and the row is listed rather than hidden", blockedButNewer.Rows.Count == 1);
		Check("and nothing offers to change the machine", !blockedButNewer.CanInstall);

		// The other side of the same distinction: nothing newer exists at all.
		var nothingNewer = new MainWindowViewModel(new[]
		{
			Release("1.0.0.100", newer: false),
		});
		Check("a channel offering only OLDER releases IS 'up to date'",
			nothingNewer.Header == "Your software is up to date.");
		Check("and the older release is still listed, with its reason",
			nothingNewer.Rows.Count == 1
			&& nothingNewer.Rows[0].Block == ReleaseBlock.NotNewer);

		// The exact machine case: one newer-but-development, one older.
		var benchCase = new MainWindowViewModel(new[]
		{
			Release("1.0.0.164", applicable: true, newer: true, development: true,
				signingKey: "OS/7 DEVELOPMENT signing key"),
			Release("1.0.0.162", newer: false, development: true),
		});
		Check("the machine's own case does not claim to be up to date",
			benchCase.Header
				== "New software exists, but none of it can be installed on this computer.");
		Check("and neither row can be ticked", benchCase.InstallableCount == 0);
		Check("and the newest is listed first",
			benchCase.Rows[0].Version == "1.0.0.164");

		var one = new MainWindowViewModel(new[]
		{
			Release("1.0.0.204", applicable: true, newer: true),
		});
		Check("one installable release is 'new software is available'",
			one.Header == "New software is available for your computer.");
		Check("the newest installable release arrives pre-selected",
			one.SelectedCount == 1);
		Check("the button counts one item, singular",
			one.InstallButtonText == "Install 1 Item");
		Check("and install is possible", one.CanInstall);
		Check("the restart notice is shown BEFORE installing, not after",
			one.ShowRestartNotice);

		var two = new MainWindowViewModel(new[]
		{
			Release("1.0.0.204", applicable: true, newer: true),
			Release("1.0.0.205", applicable: true, newer: true),
		});
		Check("exactly one row is pre-selected even when several could be",
			two.SelectedCount == 1);

		two.Rows.First(r => !r.IsSelected).IsSelected = true;
		Check("two selected rows count as two items, plural",
			two.InstallButtonText == "Install 2 Items");

		Check("a release declaring no migrations reads 'none', not blank",
			one.DetailMigrations == "none");
	}

	private static void Ordering()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  Versions sort as versions");

		var model = new MainWindowViewModel(new[]
		{
			Release("1.0.0.9", applicable: true, newer: true),
			Release("1.0.0.31", applicable: true, newer: true),
		});

		Check("1.0.0.31 is listed above 1.0.0.9",
			model.Rows[0].Version == "1.0.0.31");
		Check("the string comparison it replaces would have been wrong",
			string.CompareOrdinal("1.0.0.31", "1.0.0.9") < 0);
		Check("and the pre-selected release is the newest one",
			model.Rows.Single(r => r.IsSelected).Version == "1.0.0.31");
	}

	// --------------------------------------------------------------- sizes

	private static void Sizes()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  Size is summed from what the descriptor states");

		var sized = Release("1.0.0.204", applicable: true, newer: true);
		sized = new Os7Release
		{
			Version = sized.Version,
			Applicable = true,
			Newer = true,
			Descriptor = new Os7ReleaseDescriptor
			{
				Components = new[]
				{
					new Os7Component { Package = "os7-base", Size = 1024 * 1024 },
					new Os7Component { Package = "os7-module", Size = 512 * 1024 },
				},
			},
		};

		Check("the sizes of the components are added up",
			sized.DownloadSizeBytes == (1024 * 1024) + (512 * 1024));
		Check("and shown in MiB", Row(sized).Size == "1.5 MiB");

		Check("a release whose descriptor states no sizes shows a dash, not 0.0 MiB",
			ReleaseRow.FormatSize(0) == "—");
		Check("something under a mebibyte is shown in KiB",
			ReleaseRow.FormatSize(4096) == "4 KiB");

		Console.Error.WriteLine();
		Console.Error.WriteLine("  A release date is a date, whatever shape it arrives in");

		// It arrives already rendered in the machine's culture, because
		// Get-OS7Release does [string] over a value ConvertFrom-Json made a
		// [datetime]. Both shapes must come back as the same ISO date.
		Check("an ISO timestamp becomes an ISO date",
			ReleaseRow.FormatDate("2026-09-14T15:04:30Z") == "2026-09-14");
		Check("a US-rendered timestamp becomes the same ISO date",
			ReleaseRow.FormatDate("09/14/2026 15:04:30") == "2026-09-14");
		Check("and so does a German-rendered one",
			ReleaseRow.FormatDate("14.09.2026 15:04:30") == "2026-09-14");
		Check("something that is not a date is shown as it arrived, not blanked",
			ReleaseRow.FormatDate("whenever") == "whenever");
		Check("and nothing stays nothing", ReleaseRow.FormatDate(null) == string.Empty);

		// THE LIMIT, ASSERTED SO IT IS NOT MISTAKEN FOR A BUG LATER. A date
		// whose day is 12 or less is genuinely ambiguous as text — 05/06/2026
		// is May 6th to en-US and 5 June to en-GB — and only the culture that
		// RENDERED it can say which. On a machine whose culture is not that
		// one, this repair reads it as the current culture does, and is
		// silently wrong. That is why fixing Get-OS7Release is owed rather
		// than optional.
		var ambiguous = ReleaseRow.FormatDate("05/06/2026");
		Check("an ambiguous date still produces SOMETHING rather than falling through",
			ambiguous.StartsWith("2026-", StringComparison.Ordinal));
	}

	// ----------------------------------------------------------- unit names

	private static void UnitNames()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  Only a version may become part of a unit name");

		Check("a four-field version makes the expected unit",
			UpdateRunner.UnitNameFor("1.0.0.204") == "os7-update@1.0.0.204.service");

		foreach (var bad in new[]
		{
			"1.0.0.204 x", "../../etc", "1.0.0.204;reboot", "", "latest", "1.0.0.204\n",
		})
		{
			var threw = false;
			try
			{
				UpdateRunner.UnitNameFor(bad);
			}
			catch (ArgumentException)
			{
				threw = true;
			}

			Check($"'{bad.Replace("\n", "\\n")}' is refused, not escaped", threw);
		}
	}

	// --------------------------------------------------------------- plumbing

	private static ReleaseRow Row(Os7Release release) => new(release);

	private static Os7Release Release(
		string version,
		bool applicable = false,
		bool newer = false,
		bool crossesMajor = false,
		bool foreignArch = false,
		bool hotfix = false,
		string? hotfixBase = null,
		bool development = false,
		string? signingKey = null,
		string? arch = null) =>
		new()
		{
			Version = version,
			Channel = "preview",
			Released = "2026-09-14",
			Architecture = arch ?? "amd64",
			Applicable = applicable,
			Newer = newer,
			CrossesMajor = crossesMajor,
			ForeignArchitecture = foreignArch,
			Hotfix = hotfix,
			HotfixBase = hotfixBase,
			Development = development,
			SigningKey = signingKey,
		};

	private static void Check(string what, bool ok)
	{
		Console.Error.WriteLine($"      {(ok ? "ok  " : "FAIL")}  {what}");

		if (ok)
		{
			_pass++;
		}
		else
		{
			Failures.Add(what);
		}
	}
}
