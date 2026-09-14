using OS7.App.Versions.Model;
using OS7.App.Versions.Services;

namespace OS7.App.Versions;

/// <summary>
/// Every decision this application makes, asked without ZFS, without snapshots
/// and without a machine.
/// </summary>
/// <remarks>
/// The precedent is <c>os7-setup --self-test</c> and
/// <c>os7-software-update --self-test</c>. What it does NOT check is anything
/// about how the window looks — no window is constructed here, and O-V1 (does
/// the cascade read as depth) is owed to a machine.
/// </remarks>
public static class SelfTest
{
	private static int _pass;
	private static readonly List<string> Failures = new();

	/// <summary>A real line, copied from the bench's /proc/self/mountinfo.</summary>
	private const string RealZfsLine =
		"36 25 0:31 / /home/os7admin rw,relatime shared:1 - zfs "
		+ "rpool/USERDATA/os7admin_af456a8e rw,xattr,noacl,casesensitive";

	public static int Run()
	{
		Console.Error.WriteLine("OS/7 Versions self-test");

		Mounts();
		Paths();
		Collapsing();
		Refusals();
		Captions();

		Console.Error.WriteLine();
		Console.Error.WriteLine($"  {_pass} ok, {Failures.Count} failed");

		foreach (var failure in Failures)
		{
			Console.Error.WriteLine($"    FAILED: {failure}");
		}

		return Failures.Count == 0 ? 0 : 1;
	}

	// -------------------------------------------------------------- mounts

	private static void Mounts()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  The kernel's mount table, parsed as the kernel writes it");

		var mounts = MountTable.Parse(new[] { RealZfsLine });
		Check("a real zfs line yields one mount", mounts.Count == 1);
		Check("with the mount point", mounts[0].MountPoint == "/home/os7admin");
		Check("the filesystem type", mounts[0].FsType == "zfs");
		Check("and the dataset", mounts[0].Source == "rpool/USERDATA/os7admin_af456a8e");
		Check("and it knows it is ZFS", mounts[0].IsZfs);

		// THE OPTIONAL FIELDS ARE WHY THIS IS SPLIT ON " - ". Between the mount
		// point and the separator the kernel writes a VARIABLE number of them,
		// so counting fields from either end is wrong.
		var many = MountTable.Parse(new[]
		{
			"36 25 0:31 / /srv rw shared:1 master:2 propagate_from:3 - zfs rpool/DATA/srv rw",
		});
		Check("three optional fields do not move the filesystem type",
			many.Count == 1 && many[0].FsType == "zfs" && many[0].MountPoint == "/srv");

		var none = MountTable.Parse(new[] { "36 25 0:31 / /boot rw - zfs bpool/BOOT rw" });
		Check("and neither does none of them",
			none.Count == 1 && none[0].Source == "bpool/BOOT");

		Check("a line with no separator is skipped, not guessed at",
			MountTable.Parse(new[] { "nonsense" }).Count == 0);

		// A home directory with a space in it is ordinary, and mountinfo
		// octal-escapes it. Reading it raw resolves to the wrong mount.
		Check("an octal-escaped space is decoded",
			MountTable.Unescape(@"/home/a\040b") == "/home/a b");
		Check("a backslash that is not an escape survives",
			MountTable.Unescape(@"/home/a\b") == @"/home/a\b");
	}

	private static void Paths()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  Which dataset a path is on, and where its history lives");

		var mounts = MountTable.Parse(new[]
		{
			"1 0 0:1 / / rw - zfs rpool/ROOT/os7 rw",
			RealZfsLine,
			"40 25 0:40 / /home/os7admin/media rw - vfat /dev/sdb1 rw",
		});

		var home = MountTable.For("/home/os7admin/notes.txt", mounts);
		Check("the LONGEST matching mount point wins, not the first",
			home?.MountPoint == "/home/os7admin");

		Check("a file on the root dataset finds the root",
			MountTable.For("/etc/hostname", mounts)?.Source == "rpool/ROOT/os7");

		// THE PREFIX TRAP: /home/os7admin2 starts with /home/os7admin and is a
		// different user. Getting this wrong shows one person another's files.
		var otherUser = MountTable.Parse(new[]
		{
			RealZfsLine,
			"37 25 0:32 / /home/os7admin2 rw - zfs rpool/USERDATA/os7admin2_b1 rw",
		});
		Check("a longer NAME is not a deeper PATH",
			MountTable.For("/home/os7admin2/secret.txt", otherUser)?.Source
				== "rpool/USERDATA/os7admin2_b1");
		Check("and the boundary is a separator, not a character count",
			!MountTable.IsUnder("/home/os7admin2", "/home/os7admin"));
		Check("while the directory itself IS under itself",
			MountTable.IsUnder("/home/os7admin", "/home/os7admin"));

		Check("the path below the mount point is what goes into the snapshot",
			MountTable.RelativeTo("/home/os7admin/a/b.txt", "/home/os7admin") == "a/b.txt");
		Check("the mount point itself is the empty remainder",
			MountTable.RelativeTo("/home/os7admin", "/home/os7admin") == string.Empty);
		Check("and the root is a special case that does not double its slash",
			MountTable.RelativeTo("/etc/hostname", "/") == "etc/hostname");

		Check("a trailing slash does not change which mount a directory is on",
			MountTable.For("/home/os7admin/", mounts)?.MountPoint == "/home/os7admin");

		// The shape measured in M-V4.
		Check("a version's path is <mount>/.zfs/snapshot/<snap>/<rel>",
			VersionStore.PathInSnapshot("/home/os7admin", "autosnap_x", "a/b.txt")
				== "/home/os7admin/.zfs/snapshot/autosnap_x/a/b.txt");
		Check("the mount point itself resolves to the snapshot's own root",
			VersionStore.PathInSnapshot("/home/os7admin", "autosnap_x", string.Empty)
				== "/home/os7admin/.zfs/snapshot/autosnap_x");
		Check("and the root dataset does not produce a doubled slash",
			VersionStore.PathInSnapshot("/", "autosnap_x", "etc/hostname")
				== "/.zfs/snapshot/autosnap_x/etc/hostname");

		Console.Error.WriteLine();
		Console.Error.WriteLine("  A path with no history says WHICH kind of none it is");

		var onVfat = VersionStore.Resolve("/home/os7admin/media/x.jpg", mounts, _ => true, _ => false);
		Check("a file on a non-ZFS mount has no history", !onVfat.HasHistory);
		Check("and the reason is the filesystem", onVfat.Reason == NoHistoryReason.NotZfs);
		Check("and the sentence names it",
			onVfat.Explanation.Contains("vfat", StringComparison.Ordinal));

		var onZfs = VersionStore.Resolve("/home/os7admin/notes.txt", mounts, _ => true, _ => false);
		Check("a file on a ZFS dataset does have history", onZfs.HasHistory);
		Check("and its relative path is what the snapshot will be asked for",
			onZfs.RelativePath == "notes.txt");

		var nowhere = VersionStore.Resolve("/mnt/usb/x", Array.Empty<Mount>(), _ => false, _ => false);
		Check("a path on nothing we can see is NotZfs rather than a crash",
			nowhere.Reason == NoHistoryReason.NotZfs);
		Check("and every no-history reason produces a sentence",
			nowhere.Explanation.Length > 0 && onVfat.Explanation.Length > 0);
	}

	// ---------------------------------------------------------- collapsing

	private static void Collapsing()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  Identical snapshots collapse, and the OLDEST of a run is kept");

		// Newest first, as Versions() produces them. Content A A A B B C:
		// three distinct versions, and the interesting timestamp for each is
		// when it FIRST looked like that.
		var versions = new[]
		{
			Version("h18", 300, 10),
			Version("h17", 300, 10),
			Version("h16", 300, 10),
			Version("h15", 200, 9),
			Version("h14", 200, 9),
			Version("h13", 100, 8),
		};

		var distinct = VersionStore.Distinct(versions);

		Check("six snapshots of three contents give three rows", distinct.Count == 3);
		Check("and the kept row of each run is the OLDEST, not the newest",
			distinct[0].Snapshot.ShortName == "h16"
			&& distinct[1].Snapshot.ShortName == "h14"
			&& distinct[2].Snapshot.ShortName == "h13");

		// A file that appears part-way through: the older snapshots do not hold
		// it, and that boundary is a change worth showing.
		var appeared = new[]
		{
			Version("h18", 300, 10),
			Version("h17", 300, 10),
			Absent("h16"),
			Absent("h15"),
		};
		var appearedDistinct = VersionStore.Distinct(appeared);
		Check("a file that did not exist yet is a version boundary",
			appearedDistinct.Count == 2);
		Check("and the absent side is kept too, so the window can say when it appeared",
			!appearedDistinct[1].Exists);

		Check("one snapshot gives one row", VersionStore.Distinct(new[] { Version("h1", 5, 1) }).Count == 1);
		Check("no snapshots give no rows",
			VersionStore.Distinct(Array.Empty<FileVersion>()).Count == 0);

		Check("a version with nothing older than it always counts as a change",
			Version("h1", 5, 1).DiffersFrom(null));
		Check("same size and same mtime is not a change",
			!Version("h2", 5, 1).DiffersFrom(Version("h1", 5, 1)));
		Check("same size but a different mtime IS a change",
			Version("h2", 5, 2).DiffersFrom(Version("h1", 5, 1)));
	}

	// ------------------------------------------------------------ refusals

	private static void Refusals()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  Only a dataset name may be put into a script");

		Check("an ordinary dataset is accepted",
			ZfsCli.IsWellFormedDataset("rpool/USERDATA/os7admin_af456a8e"));
		Check("and one with a colon, which ZFS allows",
			ZfsCli.IsWellFormedDataset("rpool/os7:data"));

		foreach (var bad in new[]
		{
			"rpool'; rm -rf /", "rpool/x@snap", "rpool/x`id`", "rpool/x$(id)",
			"rpool/x y", "rpool/x\n", "",
		})
		{
			Check($"'{bad.Replace("\n", "\\n")}' is refused, not escaped",
				!ZfsCli.IsWellFormedDataset(bad));
		}

		Console.Error.WriteLine();
		Console.Error.WriteLine("  A snapshot's name is split, never parsed for meaning");

		var snap = new SnapshotRef
		{
			Name = "rpool/USERDATA/os7admin_af456a8e@autosnap_2026-09-14_18:00:02_hourly",
			Creation = DateTimeOffset.Parse("2026-09-14T20:00:02+02:00"),
		};
		Check("the directory name is the part after the @",
			snap.ShortName == "autosnap_2026-09-14_18:00:02_hourly");
		Check("the dataset is the part before it",
			snap.Dataset == "rpool/USERDATA/os7admin_af456a8e");
		Check("sanoid's retention bucket is read off the name", snap.Bucket == "hourly");

		// The one an administrator took by hand, which name-parsing would lose.
		var manual = new SnapshotRef { Name = "rpool/USERDATA/x@before-the-migration" };
		Check("a hand-made snapshot has no bucket and is still a snapshot",
			manual.Bucket is null && manual.ShortName == "before-the-migration");
	}

	private static void Captions()
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine("  Two versions never wear the same caption");

		// MEASURED ON A MACHINE: three snapshots taken inside one minute drew
		// three identical rows, and the rows are the thing being chosen
		// between.
		var sameMinute = new[]
		{
			Entry("2026-09-14T20:39:10+02:00"),
			Entry("2026-09-14T20:39:20+02:00"),
			Entry("2026-09-14T20:39:31+02:00"),
		};
		ViewModels.VersionEntry.AssignCaptions(sameMinute);

		// ASSERTED BY SHAPE, NOT BY VALUE. The caption is rendered in the
		// MACHINE's local time, so an expected string bakes in the timezone of
		// whoever ran the check: these very assertions were written as
		// "2026-09-14 20:39:10" and went red in a UTC container while being
		// green on a +02:00 machine. A check that only passes in one timezone
		// is a check about the test host.
		Check("three snapshots in one minute get three DIFFERENT captions",
			sameMinute.Select(e => e.Caption).Distinct().Count() == 3);
		Check("and they gain seconds to do it",
			sameMinute.All(e => e.Caption.Count(c => c == ':') == 2));

		var farApart = new[]
		{
			Entry("2026-09-14T18:00:02+02:00"),
			Entry("2026-09-13T18:00:41+02:00"),
		};
		ViewModels.VersionEntry.AssignCaptions(farApart);
		Check("snapshots a day apart stay at minute resolution",
			farApart.All(e => e.Caption.Count(c => c == ':') == 1));
		Check("and a caption is still an ISO date",
			farApart[0].Caption.StartsWith("2026-09-1", StringComparison.Ordinal));

		// One format for the whole list: a list with two in it is worse than
		// either.
		var mixed = new[]
		{
			Entry("2026-09-14T20:39:10+02:00"),
			Entry("2026-09-14T20:39:20+02:00"),
			Entry("2026-09-01T09:00:00+02:00"),
		};
		ViewModels.VersionEntry.AssignCaptions(mixed);
		Check("and when seconds are needed, EVERY row gets them",
			mixed.All(e => e.Caption.Count(c => c == ':') == 2));

		var withLive = new[] { Current(), Entry("2026-09-14T20:39:10+02:00") };
		ViewModels.VersionEntry.AssignCaptions(withLive);
		Check("the live file is always 'Now', whatever the format",
			withLive[0].Caption == "Now");

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

	// ------------------------------------------------------------ plumbing

	private static ViewModels.VersionEntry Entry(string creation) =>
		new(new FileVersion(
				new SnapshotRef
				{
					Name = "rpool/x@s" + creation.GetHashCode().ToString("x8"),
					Creation = DateTimeOffset.Parse(creation),
				},
				"/home/os7admin/.zfs/snapshot/s/notes.txt",
				VersionState.Present, 10, default),
			isCurrent: false);

	private static ViewModels.VersionEntry Current() =>
		new(new FileVersion(
				new SnapshotRef { Name = "rpool/x", Creation = DateTimeOffset.Now },
				"/home/os7admin/notes.txt", VersionState.Present, 10, default),
			isCurrent: true);

	private static FileVersion Version(string snap, long size, int minute) =>
		new(new SnapshotRef { Name = $"rpool/x@{snap}" },
			$"/home/os7admin/.zfs/snapshot/{snap}/notes.txt",
			VersionState.Present,
			size,
			new DateTimeOffset(2026, 9, 14, 12, minute, 0, TimeSpan.Zero));

	private static FileVersion Absent(string snap) =>
		new(new SnapshotRef { Name = $"rpool/x@{snap}" },
			$"/home/os7admin/.zfs/snapshot/{snap}/notes.txt",
			VersionState.Absent,
			0,
			default);

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
