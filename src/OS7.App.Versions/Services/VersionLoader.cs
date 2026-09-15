using System.Text.Json;
using OS7.App.Versions.Model;
using OS7.App.Versions.ViewModels;
using OS7.Shell;

namespace OS7.App.Versions.Services;

/// <summary>What loading a path's history produced.</summary>
/// <param name="Entries">The versions, newest first.</param>
/// <param name="Error">
/// Null when the question was answered. Otherwise the machine's own words —
/// never this application's paraphrase of them.
/// </param>
public sealed record LoadResult(IReadOnlyList<VersionEntry> Entries, string? Error);

/// <summary>
/// The versions of a path, from the PowerShell surface.
/// </summary>
/// <remarks>
/// <para>
/// docs/GUI-APPS-PLAN.md G3/G4 and VERSIONS-PLAN V9. <c>Get-OS7FileVersion</c>
/// is the authority: it resolves which dataset owns the path, asks ZFS for the
/// snapshot times, reads each one, and decides which versions are worth
/// showing. This arranges what comes back.
/// </para>
/// <para>
/// EVERY REFUSAL IS THE CMDLET'S OWN SENTENCE. "'/proc/cpuinfo' is not inside a
/// mounted ZFS filesystem, so it has no snapshots" and "'/home/u' IS the
/// mountpoint of rpool/USERDATA/u — name a file or a folder inside it" are
/// written once, in the cmdlet, and reach the window unaltered. An application
/// that rewrote them into "no versions found" would delete the instruction they
/// carry, which is VERSIONS-PLAN V6's whole point.
/// </para>
/// <para>
/// THE ONE THING STILL DONE HERE is reading a version's contents for the
/// preview, and that is <see cref="TextPreview"/>: bytes, not decisions, and a
/// `pwsh` launch per preview would make the window unusable.
/// </para>
/// </remarks>
public sealed class VersionLoader
{
	private static readonly JsonSerializerOptions Json = new()
	{
		PropertyNameCaseInsensitive = true,
	};

	private readonly PowerShellRunner _shell;

	public VersionLoader(PowerShellRunner? shell = null) => _shell = shell ?? new PowerShellRunner();

	/// <summary>
	/// Build the script for one path.
	/// </summary>
	/// <remarks>
	/// The path is passed through a HERE-STRING with single quotes, which
	/// PowerShell does not expand and which cannot be closed from inside by
	/// anything a filename may contain — a file called <c>'; rm -rf ~ #</c> is
	/// legal on Linux and would end an ordinary quoted string.
	/// </remarks>
	public static string ScriptFor(string path)
	{
		return "Import-Module OS7 -ErrorAction Stop; "
			+ "$p = @'\n" + path + "\n'@; "
			+ "Get-OS7FileVersion -Path $p -DistinctOnly -IncludeCurrent -IncludeAbsent | "
			+ "Select-Object Path, Dataset, SnapshotName, Snapshot, Created, Modified, "
			+ "Length, IsFolder, IsCurrent, Exists, SnapshotPath | "
			+ "ConvertTo-Json -Depth 4 -AsArray";
	}

	/// <summary>
	/// The one line that puts a version back — and it is a CMDLET CALL.
	/// </summary>
	/// <remarks>
	/// <para>
	/// VERSIONS-PLAN V9. The window performs no restore of its own: no copy, no
	/// rename, no snapshot. `Restore-OS7File` owns which version, what is kept
	/// first, whether that is a ZFS snapshot or a file moved aside (V8/V19), and
	/// every refusal — and an administrator over ssh gets the identical
	/// behaviour, which is the whole of G3.
	/// </para>
	/// <para>
	/// -Force because the live file exists and is exactly what is being
	/// replaced; the cmdlet requires it for an in-place restore precisely so
	/// that no caller does this by accident. The operator has already been asked
	/// in the window's own words.
	/// </para>
	/// <para>
	/// -Confirm:$false because the confirmation has HAPPENED — in a dialog the
	/// operator could read, naming the file and the moment. A second prompt on a
	/// stream nobody is watching would hang the run until the window gave up.
	/// </para>
	/// <para>
	/// Both the path and the snapshot name go through here-strings, for the
	/// reason ScriptFor gives: a snapshot name is ZFS's and a path is the
	/// operator's, and neither is this application's syntax.
	/// </para>
	/// </remarks>
	public static string RestoreScriptFor(string path, string snapshot)
	{
		return "Import-Module OS7 -ErrorAction Stop; "
			+ "$p = @'\n" + path + "\n'@; "
			+ "$s = @'\n" + snapshot + "\n'@; "
			+ "Restore-OS7File -Path $p -Snapshot $s -Force -Confirm:$false | "
			+ "Select-Object RestoredTo, SnapshotName, SafetySnapshot, SafetyCopy | "
			+ "ConvertTo-Json -Depth 3";
	}

	/// <summary>
	/// Put a version back, and report what the machine said either way.
	/// </summary>
	public async Task<string?> RestoreAsync(
		string path, string snapshot, CancellationToken ct = default)
	{
		var result = await _shell
			.RunAsync(RestoreScriptFor(path, snapshot), ct)
			.ConfigureAwait(false);

		// THE CMDLET'S OWN SENTENCE, UNALTERED (V6). "'/home/u' IS the mountpoint
		// of rpool/USERDATA/u — name a file or a folder inside it" is written
		// once; an application that rewrote it into "restore failed" would delete
		// the instruction it carries.
		return result.Ok ? null : result.Message;
	}

	public async Task<LoadResult> LoadAsync(string path, CancellationToken ct = default)
	{
		var result = await _shell.RunAsync(ScriptFor(path), ct).ConfigureAwait(false);

		if (!result.Ok)
		{
			return new LoadResult(Array.Empty<VersionEntry>(), result.Message);
		}

		if (string.IsNullOrWhiteSpace(result.Stdout))
		{
			return new LoadResult(Array.Empty<VersionEntry>(), null);
		}

		List<FileVersion>? versions;
		try
		{
			versions = JsonSerializer.Deserialize<List<FileVersion>>(result.Stdout, Json);
		}
		catch (JsonException ex)
		{
			return new LoadResult(
				Array.Empty<VersionEntry>(),
				$"the version list could not be read: {ex.Message}");
		}

		if (versions is null || versions.Count == 0)
		{
			return new LoadResult(Array.Empty<VersionEntry>(), null);
		}

		// The cmdlet emits oldest first; the window reads newest first, because
		// "now" is where somebody starts and walks backwards from.
		var entries = versions
			.OrderByDescending(v => v.IsCurrent)
			.ThenByDescending(v => v.Created)
			.Select(v => new VersionEntry(v))
			.ToList();

		VersionEntry.AssignCaptions(entries);

		return new LoadResult(entries, null);
	}
}
