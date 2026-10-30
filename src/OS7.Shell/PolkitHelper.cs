using System.Diagnostics;
using System.Text.RegularExpressions;

namespace OS7.Shell;

/// <summary>
/// The one way an OS/7 application reaches something as root: an OS/7 helper,
/// started through <c>pkexec</c>, behind a polkit action.
/// </summary>
/// <remarks>
/// <para>
/// docs/GUI-APPS-PLAN.md G5 and docs/CONTAINERS-PLAN.md CT5. An application
/// never runs as root and never asks for a password itself: pkexec asks polkit,
/// polkit asks the operator in its OWN dialog, and the application only learns
/// the answer. <c>pkexec pwsh</c> — a whole shell as root — is what G5 refuses;
/// this starts a named helper whose verbs are a fixed table, and nothing else.
/// </para>
/// <para>
/// THE PROGRAM IS NOT THE CALLER'S TO CHOOSE. A caller names a helper
/// (<c>os7-container-helper</c>); this class puts <c>/usr/libexec/</c> in front
/// of it and refuses any name that is not <c>os7-</c> and lower-case letters,
/// digits and dashes. polkit's action is keyed on that exact path
/// (<c>org.freedesktop.policykit.exec.path</c>), so a path assembled from
/// anything else would either be refused by polkit or, worse, match an action
/// meant for something else. installer/testing/check-gui-logic.py holds that
/// this is the only file under src/ allowed to name pkexec.
/// </para>
/// <para>
/// pkexec's own exit codes are part of its contract and are read here, once:
/// 126 when the operator dismissed the dialog, 127 when the authorisation was
/// refused or the helper could not be run. Anything else is the helper's.
/// </para>
/// </remarks>
public sealed class PolkitHelper
{
	/// <summary>Where every OS/7 helper lives.</summary>
	public const string HelperDirectory = "/usr/libexec/";

	/// <summary>pkexec: the operator closed the authentication dialog.</summary>
	public const int Dismissed = 126;

	/// <summary>pkexec: not authorised, or the helper could not be run.</summary>
	public const int NotAuthorized = 127;

	private static readonly Regex HelperName = new(@"^os7-[a-z0-9-]+$", RegexOptions.Compiled);

	private readonly string _pkexec;

	/// <param name="pkexecPath">
	/// Named, not searched; <c>OS7_PKEXEC</c> lets a harness point elsewhere
	/// without this class growing a search.
	/// </param>
	public PolkitHelper(string? pkexecPath = null)
	{
		_pkexec = pkexecPath
			?? Environment.GetEnvironmentVariable("OS7_PKEXEC")
			?? "pkexec";
	}

	/// <summary>The absolute path a helper name stands for, or an exception.</summary>
	public static string PathFor(string helper)
	{
		if (!HelperName.IsMatch(helper))
		{
			throw new ArgumentException(
				$"'{helper}' is not an OS/7 helper name (os7-, then lower-case letters, digits and dashes).",
				nameof(helper));
		}

		return HelperDirectory + helper;
	}

	/// <summary>Whether a result is the operator having said no in polkit's dialog.</summary>
	public static bool WasDismissed(ShellResult result) => result.ExitCode == Dismissed;

	/// <summary>Run one helper verb as root, with polkit's consent.</summary>
	public async Task<ShellResult> RunAsync(
		string helper,
		IReadOnlyList<string> arguments,
		string? standardInput,
		CancellationToken ct = default)
	{
		var psi = new ProcessStartInfo
		{
			FileName = _pkexec,
			RedirectStandardOutput = true,
			RedirectStandardError = true,
			RedirectStandardInput = standardInput is not null,
			UseShellExecute = false,
		};

		// As separate arguments, never as one command line — and pkexec takes
		// the program's arguments verbatim after its path.
		psi.ArgumentList.Add(PathFor(helper));
		foreach (var argument in arguments)
		{
			psi.ArgumentList.Add(argument);
		}

		var result = await ProcessRun.RunAsync(psi, standardInput, _pkexec, ct).ConfigureAwait(false);

		if (result.ExitCode is Dismissed or NotAuthorized && string.IsNullOrWhiteSpace(result.Stderr))
		{
			return result with
			{
				Stderr = result.ExitCode == Dismissed
					? "The authentication dialog was closed, so nothing was done."
					: "polkit did not authorise this, or the helper is not installed.",
			};
		}

		return result;
	}
}
