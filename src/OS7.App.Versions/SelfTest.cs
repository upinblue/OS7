using OS7.App.Versions.Model;
using OS7.App.Versions.Services;
using OS7.App.Versions.ViewModels;

namespace OS7.App.Versions;

/// <summary>
/// Every decision this application makes, asked without PowerShell, without ZFS
/// and without a display.
/// </summary>
/// <remarks>
/// <para>
/// IT IS SHORTER THAN IT WAS, and that is the point. This application used to
/// resolve which dataset a path was on and collapse runs of identical versions
/// in C# of its own; those are decisions and they now live in
/// <c>Get-OS7FileVersion</c>, where an administrator over ssh gets them too
/// (G3/G7). Their checks went with them, to
/// <c>installer/testing/check-storage-logic.py</c> §5 and §6.
/// </para>
/// <para>
/// What is left here is what a window decides: how a timestamp is written, what
/// a version is called, which verb is offered, and what to say when there is
/// nothing to show.
/// </para>
/// </remarks>
public static class SelfTest
{
	private static int _pass;
	private static readonly List<string> Failures = new();

	public static int Run()
	{
		Console.Error.WriteLine("OS/7 Versions self-test");

		Captions();
		Rows();
		Window();
		Script();
		Preview();

		Console.Error.WriteLine();
		Console.Error.WriteLine($"  {_pass} ok, {Failures.Count} failed");

		foreach (var failure in Failures)
		{
			Console.Error.WriteLine($"    FAILED: {failure}");
		}

		return Failures.Count == 0 ? 0 : 1;
	}

	// ------------------------------------------------------------- captions

	private static void Captions()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  Two versions never wear the same caption");

		// ASSERTED BY SHAPE, NOT BY VALUE. The caption is rendered in the
		// MACHINE's local time, so an expected string bakes in the timezone of
		// whoever ran the check: these assertions were written as
		// "2026-09-14 20:39:10" and went red in a UTC container while being
		// green on a +02:00 machine.
		var sameMinute = new[]
		{
			Entry("2026-09-14T20:39:10+02:00"),
			Entry("2026-09-14T20:39:20+02:00"),
			Entry("2026-09-14T20:39:31+02:00"),
		};
		VersionEntry.AssignCaptions(sameMinute);

		Check("three snapshots in one minute get three DIFFERENT captions",
			sameMinute.Select(e => e.Caption).Distinct().Count() == 3);
		Check("and they gain seconds to do it",
			sameMinute.All(e => e.Caption.Count(c => c == ':') == 2));

		var farApart = new[]
		{
			Entry("2026-09-14T18:00:02+02:00"),
			Entry("2026-09-13T18:00:41+02:00"),
		};
		VersionEntry.AssignCaptions(farApart);
		Check("snapshots a day apart stay at minute resolution",
			farApart.All(e => e.Caption.Count(c => c == ':') == 1));
		Check("and a caption is still an ISO date",
			farApart[0].Caption.StartsWith("2026-09-1", StringComparison.Ordinal));

		var withLive = new[] { Current(), Entry("2026-09-14T20:39:10+02:00") };
		VersionEntry.AssignCaptions(withLive);
		Check("the live file is always 'Now', whatever the format",
			withLive[0].Caption == "Now");
	}

	// ----------------------------------------------------------------- rows

	private static void Rows()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  A row says what the version IS, including when it was not there");

		Check("a file is its size", Entry("2026-09-14T12:00:00Z", length: 2048).State == "2 KiB");
		Check("and a half-kibibyte rounds rather than showing a fraction nobody needs",
			Entry("2026-09-14T12:00:00Z", length: 1536).State == "2 KiB");
		Check("something under a kibibyte is counted in bytes",
			Entry("2026-09-14T12:00:00Z", length: 38).State == "38 bytes");
		Check("a folder says so", Folder().State == "folder");

		// THE BOUNDARY, which the owner asked to keep: a row saying the path
		// was not there yet is what turns a list of versions into a history.
		var absent = Absent("2026-09-14T12:00:00Z");
		Check("a version in which the path did not exist says exactly that",
			absent.State == "did not exist");
		Check("and its pane explains rather than showing an empty box",
			absent.NoPreview == "This file did not exist at this point.");
		Check("and it offers no preview to read", !absent.HasPreview);

		Check("sanoid's bucket is read off the snapshot name",
			Entry("2026-09-14T12:00:00Z", snapshot: "autosnap_2026-09-14_18:00:02_hourly")
				.Bucket == "hourly");
		Check("a hand-made snapshot is 'manual', not a parse failure",
			Entry("2026-09-14T12:00:00Z", snapshot: "before-the-migration").Bucket == "manual");
		Check("and the live file is 'live'", Current().Bucket == "live");

		// V8. The row above a restore holds the work that restore replaced, and
		// it is the one somebody comes back for.
		Check("the snapshot a restore took of your work says what it is",
			Entry("2026-09-14T12:00:00Z", snapshot: "os7-before-restore-20260914-230715")
				.Bucket == "before a restore");
		Check("including the second one in the same second",
			Entry("2026-09-14T12:00:00Z", snapshot: "os7-before-restore-20260914-230715-2")
				.Bucket == "before a restore");

		Check("an empty file is 'empty', not '0 bytes'",
			Entry("2026-09-14T12:00:00Z", length: 0).State == "empty");
	}

	// --------------------------------------------------------------- window

	private static void Window()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  The window offers a verb only where there is something to do");

		var model = new MainWindowViewModel("/home/os7admin/Angebot.txt", new[]
		{
			Current(),
			Entry("2026-09-14T20:39:05+02:00", length: 77),
			Entry("2026-09-14T20:39:02+02:00", length: 24),
			Absent("2026-09-14T20:00:02+02:00"),
		});

		Check("the newest is selected to begin with", model.SelectedIndex == 0);
		Check("and Open is offered for it", model.CanOpen);
		Check("there is nowhere forward from the newest", !model.CanGoForward);
		Check("and there is somewhere back", model.CanGoBack);

		model.SelectedIndex = 3;
		Check("stepping to the boundary offers NO verb — there is nothing to open",
			!model.CanOpen);
		Check("and there is nowhere further back", !model.CanGoBack);

		model.SelectedIndex = 0;
		Check("the subheader says how far the history reaches, not how many rows",
			model.SubHeader.Contains("back to 2026-", StringComparison.Ordinal));
		Check("and names the count as well",
			model.SubHeader.StartsWith("4 versions", StringComparison.Ordinal));

		// The cascade recedes into the PAST and the selected time is in front.
		var cascade = model.Cascade;
		Check("the cascade is oldest-first, so the panel paints the selection last",
			cascade[^1].IsFront);
		Check("and only one layer is the front one",
			cascade.Count(l => l.IsFront) == 1);

		Check("a folder is not openable either — Open would hand it to a text editor",
			new MainWindowViewModel("/x", new[] { Folder() }).CanOpen == false);

		var failed = new MainWindowViewModel("/proc/cpuinfo", Array.Empty<VersionEntry>())
		{
			Phase = VersionsPhase.Failed,
			Message = "'/proc/cpuinfo' is not inside a mounted ZFS filesystem.",
		};
		Check("a refusal is shown in the machine's own words, not paraphrased",
			failed.SubHeader == "'/proc/cpuinfo' is not inside a mounted ZFS filesystem.");
		Check("and the header says listing failed rather than 'up to date'",
			failed.Header == "Previous versions could not be listed.");
	}

	// --------------------------------------------------------------- script

	private static void Script()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  The path reaches PowerShell as data, never as syntax");

		var script = VersionLoader.ScriptFor("/home/os7admin/Angebot.txt");

		Check("it asks the cmdlet rather than doing the work itself",
			script.Contains("Get-OS7FileVersion", StringComparison.Ordinal));
		Check("with the boundary the owner asked to keep",
			script.Contains("-IncludeAbsent", StringComparison.Ordinal));
		Check("and the collapsing, so 45 snapshots are not 45 rows",
			script.Contains("-DistinctOnly", StringComparison.Ordinal));
		Check("and the live file",
			script.Contains("-IncludeCurrent", StringComparison.Ordinal));
		Check("as JSON, always an array",
			script.Contains("-AsArray", StringComparison.Ordinal));

		// A filename may contain anything but NUL and /. A here-string with
		// single quotes cannot be closed from inside by any of it.
		foreach (var nasty in new[]
		{
			"/home/u/'; rm -rf ~ #", "/home/u/$(id)", "/home/u/`id`",
			"/home/u/a\"b", "/home/u/a'b",
		})
		{
			var s = VersionLoader.ScriptFor(nasty);
			Check($"a path containing {nasty[10..]} stays inside the here-string",
				s.Contains("@'\n" + nasty + "\n'@", StringComparison.Ordinal));
		}
	}

	// -------------------------------------------------------------- preview

	private static void Preview()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  A preview is offered only for something that IS text");

		Check("plain text is text",
			TextPreview.LooksLikeText("Angebot v1 — Entwurf.\n"u8));
		Check("an empty file is text", TextPreview.LooksLikeText(ReadOnlySpan<byte>.Empty));
		Check("tabs and newlines do not make it binary",
			TextPreview.LooksLikeText("a\tb\r\nc\n"u8));

		// A NUL settles it, and every binary format has one early. The
		// extension does not come into it: BUILD-NOTES #111 is what happens
		// when a name is taken as evidence about a file's contents.
		Check("a NUL byte means binary",
			!TextPreview.LooksLikeText(new byte[] { 0x50, 0x4B, 0x03, 0x04, 0x00 }));
		Check("and so does a prefix that is mostly control characters",
			!TextPreview.LooksLikeText(new byte[] { 1, 2, 3, 4, 5, 6, 7, 8, 11, 14 }));
	}

	// ------------------------------------------------------------- plumbing

	private static VersionEntry Entry(
		string created, long? length = 10, string? snapshot = "autosnap_x_hourly") =>
		new(new FileVersion
		{
			Path = "/home/os7admin/notes.txt",
			SnapshotName = snapshot,
			Snapshot = "rpool/x@" + snapshot,
			Created = DateTimeOffset.Parse(created),
			Length = length,
			IsFolder = false,
			IsCurrent = false,
			Exists = true,
			SnapshotPath = "/home/os7admin/.zfs/snapshot/x/notes.txt",
		});

	private static VersionEntry Absent(string created) =>
		new(new FileVersion
		{
			Path = "/home/os7admin/notes.txt",
			SnapshotName = "autosnap_y_hourly",
			Created = DateTimeOffset.Parse(created),
			Length = null,
			Exists = false,
			SnapshotPath = "/home/os7admin/.zfs/snapshot/y/notes.txt",
		});

	private static VersionEntry Folder() =>
		new(new FileVersion
		{
			Path = "/home/os7admin/Dokumente",
			SnapshotName = "autosnap_z_daily",
			Created = DateTimeOffset.Parse("2026-09-14T12:00:00Z"),
			Length = null,
			IsFolder = true,
			Exists = true,
			SnapshotPath = "/home/os7admin/.zfs/snapshot/z/Dokumente",
		});

	private static VersionEntry Current() =>
		new(new FileVersion
		{
			Path = "/home/os7admin/notes.txt",
			SnapshotName = null,
			Created = DateTimeOffset.Now,
			Length = 38,
			IsCurrent = true,
			Exists = true,
			SnapshotPath = "/home/os7admin/notes.txt",
		});

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
