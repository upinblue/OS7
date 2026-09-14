using System.Text.Json;
using OS7.App.Versions.Model;
using OS7.Shell;

namespace OS7.App.Versions.Services;

/// <summary>What asking ZFS produced.</summary>
public sealed record SnapshotQuery(IReadOnlyList<SnapshotRef> Snapshots, string? Error)
{
	public bool Ok => Error is null;
}

/// <summary>
/// The snapshots of a dataset, with their real creation times.
/// </summary>
/// <remarks>
/// <para>
/// VERSIONS-PLAN V2, and the one part of this application that leaves the
/// filesystem. It exists because <c>stat</c> on a snapshot directory reports
/// the wrong time (M-V11) and because parsing sanoid's snapshot names would
/// work only for sanoid's snapshots — losing exactly the
/// <c>@before-the-migration</c> one an administrator will go looking for.
/// </para>
/// <para>
/// THROUGH THE Zfs MODULE, NOT THROUGH `zfs`. Z1/P2: OS/7 code reaches ZFS only
/// through <c>powershell/Zfs/</c>. Measured on a machine: <c>Get-ZfsSnapshot</c>
/// runs UNPRIVILEGED, and its JSON gives <c>Creation</c> as ISO 8601 with an
/// offset — so this application never meets the culture-formatted date that bit
/// Software Update.
/// </para>
/// <para>
/// Measured cost: 570 ms for `pwsh` + `Import-Module Zfs` + the query, of which
/// nearly all is starting PowerShell. That is once per window, which is why the
/// result is held rather than re-asked.
/// </para>
/// </remarks>
public sealed class ZfsCli
{
	private static readonly JsonSerializerOptions Json = new()
	{
		PropertyNameCaseInsensitive = true,
	};

	private readonly PowerShellRunner _shell;

	public ZfsCli(PowerShellRunner? shell = null) => _shell = shell ?? new PowerShellRunner();

	/// <summary>Every snapshot of one dataset, newest first.</summary>
	public async Task<SnapshotQuery> GetSnapshotsAsync(string dataset, CancellationToken ct = default)
	{
		if (!IsWellFormedDataset(dataset))
		{
			return new SnapshotQuery(
				Array.Empty<SnapshotRef>(),
				$"'{dataset}' is not a dataset name.");
		}

		// -NoRecurse: the versions of THIS dataset. A user's home has no child
		// datasets today, and if it ever does, their snapshots are their own
		// files' history and not this path's.
		var script =
			"Import-Module Zfs -ErrorAction Stop; "
			+ $"Get-ZfsSnapshot -Name '{dataset}' -NoRecurse | "
			+ "Select-Object Name, Creation, Used, Referenced | "
			+ "ConvertTo-Json -Depth 3 -AsArray";

		var result = await _shell.RunAsync(script, ct).ConfigureAwait(false);

		if (!result.Ok)
		{
			return new SnapshotQuery(Array.Empty<SnapshotRef>(), result.Message);
		}

		if (string.IsNullOrWhiteSpace(result.Stdout))
		{
			return new SnapshotQuery(Array.Empty<SnapshotRef>(), null);
		}

		try
		{
			var snapshots = JsonSerializer.Deserialize<List<SnapshotRef>>(result.Stdout, Json)
				?? new List<SnapshotRef>();

			return new SnapshotQuery(
				snapshots.OrderByDescending(s => s.Creation).ToList(),
				null);
		}
		catch (JsonException ex)
		{
			return new SnapshotQuery(
				Array.Empty<SnapshotRef>(),
				$"the snapshot list could not be read: {ex.Message}");
		}
	}

	/// <summary>
	/// Whether a string may be put into the script as a dataset name.
	/// </summary>
	/// <remarks>
	/// ZFS names allow letters, digits and <c>_ - : . /</c> and nothing else,
	/// which excludes every character that could end the quoted string it is
	/// placed in. Refused rather than escaped, because there is no legitimate
	/// caller with anything else — and because BUILD-NOTES #151 was the last
	/// time a value on its way into a command was trusted to a pattern that
	/// nearly held.
	/// </remarks>
	public static bool IsWellFormedDataset(string? name)
	{
		if (string.IsNullOrEmpty(name) || name.Length > 255)
		{
			return false;
		}

		foreach (var c in name)
		{
			var ok = char.IsAsciiLetterOrDigit(c) || c is '_' or '-' or ':' or '.' or '/';
			if (!ok)
			{
				return false;
			}
		}

		// A snapshot name, not a dataset: the caller has the wrong thing.
		return !name.Contains('@', StringComparison.Ordinal);
	}
}
