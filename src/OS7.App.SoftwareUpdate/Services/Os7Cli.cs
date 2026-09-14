using System.Text.Json;
using OS7.App.SoftwareUpdate.Model;
using OS7.Shell;

namespace OS7.App.SoftwareUpdate.Services;

/// <summary>What asking the machine produced.</summary>
/// <param name="Releases">What the channel offers, or empty.</param>
/// <param name="Error">
/// Null when the question was answered. Otherwise the machine's own words —
/// never this application's paraphrase of them.
/// </param>
public sealed record ReleaseQuery(IReadOnlyList<Os7Release> Releases, string? Error)
{
	public bool Ok => Error is null;
}

/// <summary>
/// The update surface, as objects.
/// </summary>
/// <remarks>
/// <para>
/// docs/GUI-APPS-PLAN.md G4: the wire is the cmdlets' own objects, as JSON.
/// This does not screen-scrape formatted output and does not define a shape the
/// cmdlet does not emit.
/// </para>
/// <para>
/// The process launching, the PlainText prefix and the ANSI strip all live in
/// <see cref="PowerShellRunner"/> — shared, because they are a small
/// specification and the second copy is where one of them gets forgotten.
/// </para>
/// <para>
/// It runs UNELEVATED, because reading is not privileged (G6). The window can
/// therefore draw itself completely and truthfully before any authentication
/// happens, and the polkit prompt belongs to the button that changes something.
/// </para>
/// </remarks>
public sealed class Os7Cli
{
	private static readonly JsonSerializerOptions Json = new()
	{
		PropertyNameCaseInsensitive = true,
	};

	private readonly PowerShellRunner _shell;

	public Os7Cli(PowerShellRunner? shell = null) => _shell = shell ?? new PowerShellRunner();

	/// <summary>The runner, for callers that need the same channel.</summary>
	public PowerShellRunner Shell => _shell;

	/// <summary>
	/// <c>Get-OS7Release -Available</c>, as objects.
	/// </summary>
	public async Task<ReleaseQuery> GetAvailableReleasesAsync(CancellationToken ct = default)
	{
		// -AsArray so that one release and five releases deserialise the same
		// way. Without it ConvertTo-Json emits a bare object for a single
		// result and the parse fails on exactly the machine that has one
		// update waiting - which is the common case, not the edge case.
		const string Script =
			"Import-Module OS7 -ErrorAction Stop; " +
			"Get-OS7Release -Available | ConvertTo-Json -Depth 6 -AsArray";

		var result = await _shell.RunAsync(Script, ct).ConfigureAwait(false);

		if (!result.Ok)
		{
			// The cmdlet's own sentence. "this machine has no OS/7 repository
			// configured. Point it at one with Set-OS7UpdateChannel..." is a
			// state the operator has to see, and replacing it with "could not
			// load updates" would delete the instruction it carries.
			return new ReleaseQuery(Array.Empty<Os7Release>(), result.Message);
		}

		if (string.IsNullOrWhiteSpace(result.Stdout))
		{
			return new ReleaseQuery(Array.Empty<Os7Release>(), null);
		}

		try
		{
			var releases = JsonSerializer.Deserialize<List<Os7Release>>(result.Stdout, Json);
			return new ReleaseQuery(releases ?? new List<Os7Release>(), null);
		}
		catch (JsonException ex)
		{
			return new ReleaseQuery(
				Array.Empty<Os7Release>(),
				$"the release list could not be read: {ex.Message}");
		}
	}
}
