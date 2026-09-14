using System.Text.Json;
using System.Text.RegularExpressions;

namespace OS7.App.SoftwareUpdate.Services;

/// <summary>Where an update has got to.</summary>
public sealed record UpdateProgress(
	string ActiveState,
	string SubState,
	string Result,
	string LatestLine)
{
	/// <summary>systemd's own words for "it is still going".</summary>
	public bool Running =>
		ActiveState is "activating" or "active" or "reloading";

	/// <summary>
	/// A oneshot that finished successfully goes inactive with Result=success.
	/// `ActiveState` alone cannot tell that from "never started", which is why
	/// Result is carried too - the same reason Get-SystemdUnit returns four
	/// fields about state rather than one.
	/// </summary>
	public bool Succeeded =>
		ActiveState is "inactive" && Result is "success";

	public bool Failed =>
		ActiveState is "failed" || (Result.Length > 0 && Result != "success");
}

/// <summary>
/// Starting the update, and following it.
/// </summary>
/// <remarks>
/// <para>
/// docs/GUI-APPS-PLAN.md G5: this application runs as the operator and never as
/// root. The update runs in <c>os7-update@&lt;version&gt;.service</c>, a system
/// unit, and starting a system unit as an unprivileged user is exactly what
/// polkit governs — so the authentication happens in polkit's own dialog, which
/// this application never sees and cannot imitate.
/// </para>
/// <para>
/// IT GOES THROUGH THE POWERSHELL SURFACE, NOT THROUGH systemctl. G12's check
/// forbids an application assembly from naming <c>systemctl</c>, and this is
/// the one place where obeying it took thought rather than restraint:
/// <c>Start-SystemdUnit</c> in <c>powershell/Systemd/</c> runs the same
/// <c>systemctl start</c>, with no <c>sudo</c> and no elevation guard, so
/// polkit is reached just the same and the layer rule holds. The alternative —
/// this class shelling out itself — would have been the first exception to a
/// rule written the same week.
/// </para>
/// <para>
/// <c>Update-OS7</c> GAINS NO CODE FOR THIS. It has thirteen
/// <c>Write-OS7UpdateLog</c> calls and no <c>Write-Progress</c>, so what an
/// operator sees is the unit's latest journal line and an indeterminate bar —
/// coarse, and labelled as such rather than dressed up as a percentage.
/// Structured progress in the cmdlet is the better answer and is deliberately
/// not attempted here: it would change a cmdlet <c>run-s5.py</c>'s gate covers,
/// and that gate costs a full install-and-update cycle.
/// </para>
/// </remarks>
public sealed class UpdateRunner
{
	/// <summary>
	/// A version, and nothing else, may become part of a unit name.
	/// </summary>
	/// <remarks>
	/// The instance name is passed to systemd and appears in a unit file's
	/// <c>%i</c>. Four numeric fields is what RELEASE-AND-UPDATE-PLAN U2
	/// defines a version to be; anything else is refused here rather than
	/// escaped, because there is no legitimate caller that needs it.
	/// <para>
	/// <c>\z</c>, NOT <c>$</c>. In .NET <c>$</c> matches at the end of the
	/// string AND immediately before a trailing newline, so
	/// <c>^[0-9.]+$</c> accepts <c>"1.0.0.204\n"</c> — a newline into a systemd
	/// unit name. This was written with <c>$</c> and the self-test caught it on
	/// its first run (BUILD-NOTES #151).
	/// </para>
	/// </remarks>
	private static readonly Regex VersionShape =
		new(@"^[0-9]{1,6}(\.[0-9]{1,6}){0,3}\z", RegexOptions.Compiled);

	private readonly Os7Cli _cli;

	public UpdateRunner(Os7Cli cli) => _cli = cli;

	public static bool IsWellFormedVersion(string? version) =>
		!string.IsNullOrEmpty(version) && VersionShape.IsMatch(version);

	/// <summary>The unit that installs one release.</summary>
	/// <exception cref="ArgumentException">The version is not a version.</exception>
	public static string UnitNameFor(string version)
	{
		if (!IsWellFormedVersion(version))
		{
			throw new ArgumentException(
				$"'{version}' is not a version, and only a version may become part of a "
				+ "unit name.",
				nameof(version));
		}

		return $"os7-update@{version}.service";
	}

	/// <summary>
	/// Ask systemd to start the update. Returns null on success, or the
	/// machine's own words about why not.
	/// </summary>
	/// <remarks>
	/// The operator meets polkit here, in polkit's dialog, and a refusal to
	/// authenticate arrives as a non-zero exit from systemctl with a message
	/// that says so. It is passed through rather than translated: "Interactive
	/// authentication required" tells an administrator what happened, and
	/// "could not start update" does not.
	/// </remarks>
	public async Task<string?> StartAsync(string version, CancellationToken ct = default)
	{
		var unit = UnitNameFor(version);

		var script =
			"Import-Module Systemd -ErrorAction Stop; "
			+ $"Start-SystemdUnit -Name '{unit}' -Confirm:$false | Out-Null";

		var (exitCode, _, stderr) = await _cli.RunScriptAsync(script, ct).ConfigureAwait(false);

		if (exitCode == 0)
		{
			return null;
		}

		var message = stderr.Trim();
		return message.Length > 0
			? message
			: $"the update unit {unit} could not be started, and nothing said why.";
	}

	/// <summary>Where it has got to, asked of systemd and of the journal.</summary>
	public async Task<UpdateProgress> PollAsync(string version, CancellationToken ct = default)
	{
		var unit = UnitNameFor(version);

		// One pwsh invocation for both questions. Two would double the cost of
		// a poll that runs every second, and they are one moment in time.
		var script =
			"Import-Module Systemd -ErrorAction Stop; "
			+ $"$u = @(Get-SystemdUnit -Name '{unit}')[0]; "
			+ $"$j = @(Get-SystemdJournal -Unit '{unit}' -Tail 1); "
			+ "[pscustomobject]@{ "
			+ "  ActiveState = [string]$u.ActiveState; "
			+ "  SubState    = [string]$u.SubState; "
			+ "  Result      = [string]$u.Result; "
			+ "  Latest      = [string]($j | Select-Object -Last 1 -ExpandProperty Message) "
			+ "} | ConvertTo-Json -Depth 3";

		var (exitCode, stdout, stderr) = await _cli.RunScriptAsync(script, ct)
			.ConfigureAwait(false);

		if (exitCode != 0 || string.IsNullOrWhiteSpace(stdout))
		{
			return new UpdateProgress(string.Empty, string.Empty, string.Empty, stderr.Trim());
		}

		try
		{
			using var document = JsonDocument.Parse(stdout);
			var root = document.RootElement;

			return new UpdateProgress(
				Text(root, "ActiveState"),
				Text(root, "SubState"),
				Text(root, "Result"),
				Text(root, "Latest"));
		}
		catch (JsonException)
		{
			return new UpdateProgress(string.Empty, string.Empty, string.Empty, string.Empty);
		}
	}

	private static string Text(JsonElement element, string name) =>
		element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
			? value.GetString() ?? string.Empty
			: string.Empty;
}
