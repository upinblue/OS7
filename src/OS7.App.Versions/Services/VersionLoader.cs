using OS7.App.Versions.Model;
using OS7.App.Versions.ViewModels;

namespace OS7.App.Versions.Services;

/// <summary>What loading a path's history produced.</summary>
public sealed record LoadResult(
	VersionTarget Target,
	IReadOnlyList<VersionEntry> Entries,
	string? Error);

/// <summary>
/// The only place this application touches the disk.
/// </summary>
/// <remarks>
/// <para>
/// Everything it decides is in <see cref="VersionStore"/> and is pure; this
/// supplies the three things that are not — the mount table, the snapshot list,
/// and one <c>stat</c> per snapshot. Keeping them apart is what lets every
/// decision be checked with no ZFS and no machine.
/// </para>
/// <para>
/// It runs UNPRIVILEGED, and that is measured rather than hoped:
/// <c>su - os7admin</c> listed the snapshots and read a file out of one
/// (VERSIONS-PLAN M-V5). Browsing one's own history needs no polkit, which is
/// the difference between this window and Software Update's.
/// </para>
/// </remarks>
public sealed class VersionLoader
{
	private readonly ZfsCli _zfs;

	public VersionLoader(ZfsCli? zfs = null) => _zfs = zfs ?? new ZfsCli();

	public async Task<LoadResult> LoadAsync(string path, CancellationToken ct = default)
	{
		var mounts = MountTable.Read();
		var target = VersionStore.Resolve(path, mounts, File.Exists, Directory.Exists);

		if (!target.HasHistory || target.Mount is null)
		{
			return new LoadResult(target, Array.Empty<VersionEntry>(), null);
		}

		var query = await _zfs.GetSnapshotsAsync(target.Mount.Source, ct).ConfigureAwait(false);

		if (!query.Ok)
		{
			return new LoadResult(target, Array.Empty<VersionEntry>(), query.Error);
		}

		if (query.Snapshots.Count == 0)
		{
			return new LoadResult(
				target with { Reason = NoHistoryReason.NoSnapshots },
				Array.Empty<VersionEntry>(),
				null);
		}

		var versions = VersionStore.Versions(target, query.Snapshots, Probe);
		var distinct = VersionStore.Distinct(versions);

		// A path that exists in no snapshot at all, and not live either, is the
		// one case where "not found" is the honest answer rather than "deleted".
		if (distinct.Count == 0 || distinct.All(v => !v.Exists))
		{
			var live = Probe(target.Path);
			if (live.State == VersionState.Absent)
			{
				return new LoadResult(
					target with { Reason = NoHistoryReason.NotFound },
					Array.Empty<VersionEntry>(),
					null);
			}
		}

		var current = Probe(target.Path);
		var entries = new List<VersionEntry>();

		// The live file heads the list when it differs from the newest snapshot
		// — otherwise "Now" and the newest snapshot would be two rows saying
		// the same thing.
		var newest = distinct.Count > 0 ? distinct[0] : null;
		var liveVersion = new FileVersion(
			new SnapshotRef { Name = target.Mount.Source, Creation = DateTimeOffset.Now },
			target.Path, current.State, current.Size, current.Modified);

		if (current.State != VersionState.Absent && liveVersion.DiffersFrom(newest))
		{
			entries.Add(new VersionEntry(liveVersion, isCurrent: true));
		}

		entries.AddRange(distinct.Select(v => new VersionEntry(v, isCurrent: false)));

		return new LoadResult(target, entries, null);
	}

	/// <summary>
	/// What is at a path: one <c>stat</c>, and no exception for absence.
	/// </summary>
	/// <remarks>
	/// Absence is the ORDINARY answer here — a snapshot from before the file
	/// existed, or after it was deleted — and the deleted case is the whole
	/// point of the feature (V5). Treating it as an error would throw away the
	/// thing somebody opened the window to find.
	/// </remarks>
	public static (VersionState State, long Size, DateTimeOffset Modified) Probe(string path)
	{
		try
		{
			if (Directory.Exists(path))
			{
				return (VersionState.Directory, 0,
					new DateTimeOffset(Directory.GetLastWriteTimeUtc(path), TimeSpan.Zero));
			}

			var info = new FileInfo(path);
			if (!info.Exists)
			{
				return (VersionState.Absent, 0, default);
			}

			return (VersionState.Present, info.Length,
				new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero));
		}
		catch (Exception)
		{
			// A permission error inside a snapshot reads as absence, because
			// from this operator's side it is: they cannot see it, and saying
			// so is more useful than a dialog about EACCES.
			return (VersionState.Absent, 0, default);
		}
	}
}
