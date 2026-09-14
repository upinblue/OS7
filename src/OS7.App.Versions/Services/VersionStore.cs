using OS7.App.Versions.Model;

namespace OS7.App.Versions.Services;

/// <summary>Why a path has no version history.</summary>
public enum NoHistoryReason
{
	/// <summary>It has one.</summary>
	None,

	/// <summary>The path does not exist and never did anywhere we can see.</summary>
	NotFound,

	/// <summary>It is not on a ZFS filesystem at all — a USB stick, a network share.</summary>
	NotZfs,

	/// <summary>It is on ZFS, but nothing has ever snapshotted that dataset.</summary>
	NoSnapshots,
}

/// <summary>What was found out about a path before any versions were listed.</summary>
public sealed record VersionTarget(
	string Path,
	Mount? Mount,
	string RelativePath,
	bool IsDirectory,
	NoHistoryReason Reason)
{
	public bool HasHistory => Reason == NoHistoryReason.None;

	/// <summary>
	/// The sentence the window shows when there is nothing to show.
	/// </summary>
	/// <remarks>
	/// V6: it must never show an empty list, because an empty list means
	/// "nothing changed" and every one of these means "nothing is being kept".
	/// Those are opposite facts and they look identical as a blank table.
	/// </remarks>
	public string Explanation => Reason switch
	{
		NoHistoryReason.None => string.Empty,

		NoHistoryReason.NotFound =>
			$"There is nothing at {Path}, and no snapshot of this machine holds it either.",

		NoHistoryReason.NotZfs =>
			$"{Path} is not on this machine's ZFS storage"
			+ (Mount is null ? "." : $" — it is on {Mount.FsType}.")
			+ " Previous versions exist only for files kept on the machine's own pool.",

		NoHistoryReason.NoSnapshots =>
			$"{Path} is on {Mount?.Source}, and nothing has ever taken a snapshot of it. "
			+ "Previous versions start being kept from the first snapshot onwards.",

		_ => string.Empty,
	};
}

/// <summary>
/// Turning a path into a list of its previous versions.
/// </summary>
/// <remarks>
/// The arithmetic here is pure and is what <c>--self-test</c> exercises; the
/// I/O is in the two methods that touch the disk. Splitting them is what lets
/// every decision be checked with no ZFS, no snapshots and no machine.
/// </remarks>
public static class VersionStore
{
	/// <summary>The directory ZFS exposes snapshots under, relative to a mount point.</summary>
	public const string SnapshotDir = ".zfs/snapshot";

	/// <summary>
	/// Where a path's contents live inside one snapshot.
	/// </summary>
	/// <remarks>
	/// Pure string arithmetic over the shape measured in M-V4:
	/// <c>&lt;mountpoint&gt;/.zfs/snapshot/&lt;snapshot&gt;/&lt;path below the mountpoint&gt;</c>.
	/// </remarks>
	public static string PathInSnapshot(string mountPoint, string snapshotShortName, string relativePath)
	{
		var root = MountTable.Normalise(mountPoint);
		var baseDir = root == "/"
			? $"/{SnapshotDir}/{snapshotShortName}"
			: $"{root}/{SnapshotDir}/{snapshotShortName}";

		return string.IsNullOrEmpty(relativePath) ? baseDir : $"{baseDir}/{relativePath}";
	}

	/// <summary>Resolve a path to its dataset, without listing anything.</summary>
	public static VersionTarget Resolve(
		string path,
		IReadOnlyList<Mount> mounts,
		Func<string, bool> fileExists,
		Func<string, bool> directoryExists)
	{
		var full = MountTable.Normalise(path);
		var mount = MountTable.For(full, mounts);
		var isDirectory = directoryExists(full);
		var exists = isDirectory || fileExists(full);

		if (mount is null)
		{
			return new VersionTarget(full, null, string.Empty, isDirectory, NoHistoryReason.NotZfs);
		}

		if (!mount.IsZfs)
		{
			return new VersionTarget(full, mount, string.Empty, isDirectory, NoHistoryReason.NotZfs);
		}

		var relative = MountTable.RelativeTo(full, mount.MountPoint);

		// A path that does not exist is NOT an error: it may have been deleted,
		// and finding it is the whole point (V5). Only if nothing anywhere
		// holds it does NotFound apply, and that is decided after the snapshots
		// have been looked at, not here.
		_ = exists;

		return new VersionTarget(full, mount, relative, isDirectory, NoHistoryReason.None);
	}

	/// <summary>
	/// What one path was in each of the given snapshots, newest first.
	/// </summary>
	/// <remarks>
	/// One <c>stat</c> per snapshot. 17 ms to reach a cold snapshot directory
	/// and 16 ms to list 44 of them (M-V8, M-V9), so a policy-sized set — B5
	/// tops out near 45 per dataset — is well inside what a window may do while
	/// opening.
	/// </remarks>
	public static IReadOnlyList<FileVersion> Versions(
		VersionTarget target,
		IReadOnlyList<SnapshotRef> snapshots,
		Func<string, (VersionState State, long Size, DateTimeOffset Modified)> probe)
	{
		if (!target.HasHistory || target.Mount is null)
		{
			return Array.Empty<FileVersion>();
		}

		var versions = new List<FileVersion>();

		foreach (var snapshot in snapshots.OrderByDescending(s => s.Creation))
		{
			var path = PathInSnapshot(
				target.Mount.MountPoint, snapshot.ShortName, target.RelativePath);

			var (state, size, modified) = probe(path);
			versions.Add(new FileVersion(snapshot, path, state, size, modified));
		}

		return versions;
	}

	/// <summary>
	/// The versions worth SHOWING: consecutive identical ones collapse to the
	/// oldest of the run.
	/// </summary>
	/// <remarks>
	/// <para>
	/// Under B5 a machine takes 24 hourly snapshots a day whether anything
	/// changed or not, so a file touched twice in three months has ~45
	/// snapshots and 3 versions. Listing all 45 would bury the two moments that
	/// matter in forty-three identical rows.
	/// </para>
	/// <para>
	/// THE OLDEST OF EACH RUN IS KEPT, not the newest, and that is the one
	/// decision in this method. A run of identical snapshots means "it looked
	/// like this from T onwards"; the operator is looking for WHEN it changed,
	/// so the useful timestamp is the first one that showed the new content,
	/// not the last.
	/// </para>
	/// </remarks>
	public static IReadOnlyList<FileVersion> Distinct(IReadOnlyList<FileVersion> versions)
	{
		var result = new List<FileVersion>();

		for (var i = 0; i < versions.Count; i++)
		{
			var current = versions[i];
			var older = i + 1 < versions.Count ? versions[i + 1] : null;

			// Keep it when the next-older one differs — i.e. this is the
			// oldest snapshot still showing this content.
			if (current.DiffersFrom(older))
			{
				result.Add(current);
			}
		}

		return result;
	}
}
