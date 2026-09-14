namespace OS7.App.Versions.Model;

/// <summary>What a path looked like at one point in time.</summary>
public enum VersionState
{
	/// <summary>It was there, and it is a file.</summary>
	Present,

	/// <summary>It was there, and it is a directory.</summary>
	Directory,

	/// <summary>It did not exist yet, or had already been deleted.</summary>
	Absent,
}

/// <summary>
/// One version of one path: a snapshot, and what the path was inside it.
/// </summary>
/// <remarks>
/// <see cref="Path"/> is an ordinary filesystem path — measured (M-V4):
/// <c>/home/u/.zfs/snapshot/&lt;snap&gt;/notes.txt</c> reads back the old
/// contents, including for a file that has been deleted from the live
/// filesystem. So everything below this line is <c>System.IO</c>, and no ZFS
/// command takes part.
/// </remarks>
public sealed record FileVersion(
	SnapshotRef Snapshot,
	string Path,
	VersionState State,
	long Size,
	DateTimeOffset Modified)
{
	public bool Exists => State != VersionState.Absent;

	/// <summary>
	/// Whether this version differs from <paramref name="other"/> in a way the
	/// operator would call a change.
	/// </summary>
	/// <remarks>
	/// Size and mtime, not content. Reading both files to compare bytes turns
	/// listing twelve versions of a 2 GiB file into reading 24 GiB; ZFS itself
	/// cannot answer "are these two the same blocks" cheaply through a
	/// filesystem path either. A file rewritten with identical length and a
	/// preserved mtime therefore reads as unchanged — which is rare, and is
	/// stated rather than hidden.
	/// </remarks>
	public bool DiffersFrom(FileVersion? other)
	{
		if (other is null)
		{
			return true;
		}

		if (State != other.State)
		{
			return true;
		}

		return Size != other.Size || Modified != other.Modified;
	}
}
