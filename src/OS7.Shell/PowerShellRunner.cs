using System.Diagnostics;
using System.Text.RegularExpressions;

namespace OS7.Shell;

/// <summary>What running a script produced.</summary>
public sealed record ShellResult(int ExitCode, string Stdout, string Stderr)
{
	public bool Ok => ExitCode == 0;

	/// <summary>
	/// The machine's own words about a failure, cleaned of decoration but not
	/// of meaning.
	/// </summary>
	public string Message => Stderr.Length > 0 ? Stderr : $"pwsh exited {ExitCode} without saying why.";
}

/// <summary>
/// The one way an OS/7 application reaches the PowerShell surface.
/// </summary>
/// <remarks>
/// <para>
/// docs/GUI-APPS-PLAN.md G4. It exists as a shared library rather than once per
/// application because it is small and because the two things it gets right are
/// things that were got WRONG first and cost a machine run to find:
/// </para>
/// <list type="bullet">
///   <item><description>
///     <c>$PSStyle.OutputRendering = 'PlainText'</c>. PowerShell colours its
///     error records even with nothing attached to a terminal, and without this
///     the Software Update window drew <c>[31;1m</c> at an operator in the
///     middle of the one sentence explaining what had failed.
///   </description></item>
///   <item><description>
///     The ANSI strip below, as a belt: an application runs whatever
///     <c>pwsh</c> is on PATH, and the pin is not the only possible version.
///   </description></item>
/// </list>
/// <para>
/// A second copy of this in the next application would be a second chance to
/// forget both.
/// </para>
/// <para>
/// POWERSHELL IS NOT HOSTED IN-PROCESS. The `pwsh` on an OS/7 image is the
/// self-contained upstream tarball hook 0020 installs — Microsoft ships no
/// arm64 .deb — not a referenceable library, so Microsoft.PowerShell.SDK would
/// put a SECOND PowerShell inside every application at a version the pin does
/// not name (BUILD-NOTES #93's shape).
/// </para>
/// </remarks>
public sealed class PowerShellRunner
{
	/// <summary>
	/// Prefixed to every script. See the class remarks — this is the real fix,
	/// and <see cref="AnsiEscape"/> is the belt.
	/// </summary>
	public const string PlainTextPrefix = "$PSStyle.OutputRendering = 'PlainText'; ";

	/// <summary>ANSI SGR and cursor sequences.</summary>
	private static readonly Regex AnsiEscape =
		new(@"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])", RegexOptions.Compiled);

	private readonly string _pwsh;

	/// <param name="pwshPath">
	/// Named, not searched. `pwsh` is on PATH on every OS/7 machine; the
	/// environment variable exists so a harness can point at another one
	/// without this class growing a search.
	/// </param>
	public PowerShellRunner(string? pwshPath = null)
	{
		_pwsh = pwshPath
			?? Environment.GetEnvironmentVariable("OS7_PWSH")
			?? "pwsh";
	}

	/// <summary>Run one script and hand back what it said.</summary>
	public async Task<ShellResult> RunAsync(string script, CancellationToken ct = default)
	{
		var psi = new ProcessStartInfo
		{
			FileName = _pwsh,
			RedirectStandardOutput = true,
			RedirectStandardError = true,
			UseShellExecute = false,
		};

		// As separate arguments, never as one command line. A value reaching a
		// shell is how an argument becomes an injection.
		psi.ArgumentList.Add("-NoProfile");
		psi.ArgumentList.Add("-NonInteractive");
		psi.ArgumentList.Add("-Command");
		psi.ArgumentList.Add(PlainTextPrefix + script);

		using var process = new Process { StartInfo = psi };

		try
		{
			process.Start();
		}
		catch (Exception ex)
		{
			return new ShellResult(127, string.Empty, $"{_pwsh} could not be started: {ex.Message}");
		}

		var stdout = process.StandardOutput.ReadToEndAsync(ct);
		var stderr = process.StandardError.ReadToEndAsync(ct);

		await process.WaitForExitAsync(ct).ConfigureAwait(false);

		return new ShellResult(
			process.ExitCode,
			await stdout.ConfigureAwait(false),
			Clean(await stderr.ConfigureAwait(false)));
	}

	/// <summary>
	/// Strip the decoration, keep the message and its line breaks.
	/// </summary>
	public static string Clean(string text) =>
		string.Join(
			Environment.NewLine,
			AnsiEscape.Replace(text, string.Empty)
				.Split('\n')
				.Select(line => line.TrimEnd('\r').Trim())
				.Where(line => line.Length > 0));
}
