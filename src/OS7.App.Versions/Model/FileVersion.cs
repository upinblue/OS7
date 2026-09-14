using System.Text.Json.Serialization;

namespace OS7.App.Versions.Model;

/// <summary>
/// One version of a path, exactly as <c>Get-OS7FileVersion</c> emits it.
/// </summary>
/// <remarks>
/// <para>
/// A TRANSCRIPT, NOT A DESIGN. This mirrors the <c>OS7.Backup.FileVersion</c>
/// object built in <c>powershell/OS7/OS7.BackupRestore.ps1</c>, and the way
/// docs/GUI-APPS-PLAN.md G3 gets broken in practice is a field being
/// "simplified" on the way in.
/// </para>
/// <para>
/// THIS APPLICATION USED TO WORK ALL OF THIS OUT ITSELF — which dataset a path
/// was on, which snapshots held it, which versions were worth showing — in C#
/// of its own. That made "which versions are worth showing" a decision
/// implemented twice, in two languages, which is BUILD-NOTES #66's shape. The
/// cmdlet is the authority and this reads it.
/// </para>
/// </remarks>
public sealed class FileVersion
{
	/// <summary>The live path this is a version of.</summary>
	public string Path { get; init; } = string.Empty;

	public string? Dataset { get; init; }

	/// <summary>The snapshot's short name, or null for the live file.</summary>
	public string? SnapshotName { get; init; }

	/// <summary>The full <c>pool/dataset@snapshot</c>, or null for the live file.</summary>
	public string? Snapshot { get; init; }

	/// <summary>
	/// When the snapshot was taken — from ZFS, never from the snapshot
	/// directory's mtime, which reports something else entirely (M-V11).
	/// </summary>
	public DateTimeOffset Created { get; init; }

	public DateTimeOffset? Modified { get; init; }

	/// <summary>Null for a folder, and for a version in which the path was absent.</summary>
	public long? Length { get; init; }

	public bool IsFolder { get; init; }

	/// <summary>The live filesystem rather than a snapshot.</summary>
	public bool IsCurrent { get; init; }

	/// <summary>
	/// Whether the path was there at all.
	/// </summary>
	/// <remarks>
	/// False is THE BOUNDARY, and it is in the list on purpose (owner's
	/// decision, 2026-09-14): a row saying the path was not there yet is what
	/// turns a list of versions into a history, and it answers the question a
	/// Time-Machine window is opened with — when did this appear, or when did
	/// it go. The cmdlet reports it only with <c>-IncludeAbsent</c>, and
	/// collapses a run of them to the NEWEST, so the bracket around the change
	/// is as tight as the snapshots allow.
	/// </remarks>
	public bool Exists { get; init; }

	/// <summary>Where the bytes are: a path under <c>.zfs/snapshot</c>, or the live path.</summary>
	public string SnapshotPath { get; init; } = string.Empty;

	[JsonIgnore]
	public long Size => Length ?? 0;
}
