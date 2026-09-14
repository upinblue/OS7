using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using OS7.App.SoftwareUpdate.Model;

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
/// The bridge to the PowerShell surface, and the only way data enters this
/// application.
/// </summary>
/// <remarks>
/// <para>
/// docs/GUI-APPS-PLAN.md G4: the wire is the cmdlets' own objects, as JSON.
/// This does not screen-scrape formatted output and does not define a shape the
/// cmdlet does not emit.
/// </para>
/// <para>
/// POWERSHELL IS NOT HOSTED IN-PROCESS, and that is a measurement rather than a
/// preference. The `pwsh` on an OS/7 image is the self-contained upstream
/// tarball hook 0020 installs — Microsoft ships no arm64 .deb — not a
/// referenceable library. Taking Microsoft.PowerShell.SDK as a dependency would
/// put a SECOND PowerShell inside this application, at a version the pin does
/// not name: BUILD-NOTES #93's shape, something that looks like the product and
/// is not the product.
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

	/// <summary>
	/// Prefixed to every script. PowerShell colours its error records even when
	/// nothing is attached to a terminal, so without this the escape sequences
	/// arrive inside the message and this window printed `[31;1m` at an
	/// operator (measured on a machine, 2026-09-14).
	/// </summary>
	private const string PlainText =
		"$PSStyle.OutputRendering = 'PlainText'; ";

	private readonly string _pwsh;

	public Os7Cli(string? pwshPath = null)
	{
		// Named, not searched, with an override for a bench. `pwsh` is on PATH
		// on every OS/7 machine; the environment variable exists so a harness
		// can point at another one without this class growing a search.
		_pwsh = pwshPath
			?? Environment.GetEnvironmentVariable("OS7_PWSH")
			?? "pwsh";
	}

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

		var (exitCode, stdout, stderr) = await RunScriptAsync(Script, ct).ConfigureAwait(false);

		if (exitCode != 0)
		{
			// The cmdlet's own sentence. "this machine has no OS/7 repository
			// configured. Point it at one with Set-OS7UpdateChannel..." is a
			// state the operator has to see, and replacing it with "could not
			// load updates" would delete the instruction it carries.
			return new ReleaseQuery(
				Array.Empty<Os7Release>(),
				Clean(stderr) is { Length: > 0 } message
					? message
					: $"pwsh exited {exitCode} without saying why.");
		}

		if (string.IsNullOrWhiteSpace(stdout))
		{
			return new ReleaseQuery(Array.Empty<Os7Release>(), null);
		}

		try
		{
			var releases = JsonSerializer.Deserialize<List<Os7Release>>(stdout, Json);
			return new ReleaseQuery(releases ?? new List<Os7Release>(), null);
		}
		catch (JsonException ex)
		{
			return new ReleaseQuery(
				Array.Empty<Os7Release>(),
				$"the release list could not be read: {ex.Message}");
		}
	}

	/// <summary>
	/// Run one PowerShell script and hand back what it said, verbatim.
	/// </summary>
	/// <remarks>
	/// Public because <see cref="UpdateRunner"/> needs the same channel, and a
	/// second process-launching implementation beside this one is precisely the
	/// duplication G3 is about — in miniature, and inside one application.
	/// </remarks>
	public async Task<(int ExitCode, string Stdout, string Stderr)> RunScriptAsync(
		string script,
		CancellationToken ct = default)
	{
		var psi = new ProcessStartInfo
		{
			FileName = _pwsh,
			RedirectStandardOutput = true,
			RedirectStandardError = true,
			UseShellExecute = false,
		};

		// As separate arguments, never as one command line. A version string
		// reaching a shell is how an argument becomes an injection.
		psi.ArgumentList.Add("-NoProfile");
		psi.ArgumentList.Add("-NonInteractive");
		psi.ArgumentList.Add("-Command");
		psi.ArgumentList.Add(PlainText + script);

		using var process = new Process { StartInfo = psi };

		try
		{
			process.Start();
		}
		catch (Exception ex)
		{
			return (127, string.Empty, $"{_pwsh} could not be started: {ex.Message}");
		}

		var stdoutTask = process.StandardOutput.ReadToEndAsync(ct);
		var stderrTask = process.StandardError.ReadToEndAsync(ct);

		await process.WaitForExitAsync(ct).ConfigureAwait(false);

		return (process.ExitCode,
			await stdoutTask.ConfigureAwait(false),
			await stderrTask.ConfigureAwait(false));
	}

	/// <summary>
	/// ANSI SGR sequences — colour, bold, and the cursor moves PowerShell's
	/// error formatter emits.
	/// </summary>
	/// <remarks>
	/// Belt to <see cref="PlainText"/>'s braces. `$PSStyle.OutputRendering`
	/// exists from PowerShell 7.2 and the pin is 7.6.5, so setting it is the
	/// real fix — but this application reads whatever `pwsh` is on PATH, and a
	/// machine could have another. Stripping what arrives costs nothing.
	/// </remarks>
	private static readonly Regex AnsiEscape =
		new(@"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])", RegexOptions.Compiled);

	/// <summary>
	/// PowerShell's error records arrive with their own decoration. The message
	/// is kept; the colour codes and the blank lines around it are not.
	/// </summary>
	/// <remarks>
	/// WITHOUT THE ANSI STRIP THIS WINDOW SHOWED `[31;1m` AND `[0m` TO AN
	/// OPERATOR, in the middle of the one sentence explaining why the machine
	/// could not be asked. Measured on a machine 2026-09-14; invisible to every
	/// check in this repository, because none of them starts a `pwsh`.
	/// </remarks>
	private static string Clean(string stderr) =>
		string.Join(
			Environment.NewLine,
			AnsiEscape.Replace(stderr, string.Empty)
				.Split('\n')
				.Select(line => line.TrimEnd('\r').Trim())
				.Where(line => line.Length > 0));
}
