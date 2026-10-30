using System.Text.Json;
using OS7.Shell;

namespace OS7.App.Containers.Services;

/// <summary>How the window reaches the engine.</summary>
public enum ChannelMode
{
	/// <summary>
	/// pwsh as the operator — root, or an account in the socket's group.
	/// </summary>
	Direct,

	/// <summary>
	/// pkexec and the root helper, after polkit's dialog.
	/// </summary>
	Helper,
}

/// <summary>What one verb answered.</summary>
/// <param name="Items">The objects, always an array (the verb's contract).</param>
/// <param name="Error">
/// Null when the verb answered. Otherwise the machine's own words — never this
/// application's paraphrase.
/// </param>
/// <param name="Dismissed">The operator closed polkit's dialog.</param>
public sealed record VerbAnswer(IReadOnlyList<JsonElement> Items, string? Error, bool Dismissed = false)
{
	public bool Ok => Error is null;

	public JsonElement? First => Items.Count > 0 ? Items[0] : null;
}

/// <summary>
/// The window's one channel to the PowerShell surface, either way round.
/// </summary>
/// <remarks>
/// <para>
/// BOTH WAYS END IN THE SAME CMDLET. Directly it is
/// <c>pwsh -c "Invoke-OS7ContainerVerb …"</c>; through polkit it is
/// <c>pkexec /usr/libexec/os7-container-helper &lt;verb&gt; …</c>, and the
/// helper calls <c>Invoke-OS7ContainerVerb</c> too. So the answer has one shape
/// and one author whichever way the window was signed in.
/// </para>
/// <para>
/// ANYTHING STRUCTURED GOES ON STANDARD INPUT. A container to create carries its
/// environment, and an environment holds passwords; a process's command line is
/// readable by every account on the machine.
/// </para>
/// </remarks>
public sealed class ContainerChannel
{
	private readonly PowerShellRunner _shell;
	private readonly PolkitHelper _helper;

	public ContainerChannel(PowerShellRunner? shell = null, PolkitHelper? helper = null)
	{
		_shell = shell ?? new PowerShellRunner();
		_helper = helper ?? new PolkitHelper();
	}

	public ChannelMode Mode { get; set; } = ChannelMode.Direct;

	/// <summary>
	/// The script the direct channel runs for one verb.
	/// </summary>
	/// <remarks>
	/// Every argument goes through a SINGLE-QUOTED HERE-STRING, which PowerShell
	/// does not expand and which only a line consisting of <c>'@</c> could
	/// close. No argument may carry a line break at all, so none can.
	/// </remarks>
	public static string ScriptFor(ContainerVerb verb, IReadOnlyList<string> arguments)
	{
		foreach (var argument in arguments)
		{
			if (argument.Contains('\n') || argument.Contains('\r'))
			{
				throw new ArgumentException("A verb's argument may not contain a line break.", nameof(arguments));
			}
		}

		var quoted = string.Join(", ", arguments.Select(a => "@'\n" + a + "\n'@"));
		return "Import-Module OS7 -ErrorAction Stop; "
			+ "$a = @(" + quoted + "); "
			+ $"Invoke-OS7ContainerVerb -Verb '{verb.Name}' -Argument $a";
	}

	/// <summary>
	/// Whether a verb goes through pkexec and a root helper, rather than pwsh
	/// as this account.
	/// </summary>
	/// <remarks>
	/// Signed in through polkit: every verb. Otherwise only the INSTALL class —
	/// and that exception was found by a machine (2026-10-30): on a fresh
	/// machine there is no engine, so nobody can be signed in to one, and
	/// "Set up the engine…" ran Install-OS7ContainerHost as the user, which
	/// refused in #148's words. Installing packages is root's for every account,
	/// a container operator's included, so that verb never goes direct.
	/// </remarks>
	public static bool UsesHelper(ContainerVerb verb, ChannelMode mode) =>
		mode == ChannelMode.Helper || verb.Class == VerbClass.Install;

	/// <summary>The helper's arguments for one verb: the verb, then its own.</summary>
	public static IReadOnlyList<string> HelperArguments(ContainerVerb verb, IReadOnlyList<string> arguments) =>
		new[] { verb.Name }.Concat(arguments).ToArray();

	public async Task<VerbAnswer> RunAsync(
		ContainerVerb verb,
		IReadOnlyList<string>? arguments = null,
		string? input = null,
		CancellationToken ct = default)
	{
		var args = arguments ?? Array.Empty<string>();
		ShellResult result;

		if (UsesHelper(verb, Mode))
		{
			result = await _helper
				.RunAsync(ContainerVerbs.HelperFor(verb), HelperArguments(verb, args), input ?? (verb.TakesInput ? string.Empty : null), ct)
				.ConfigureAwait(false);

			if (PolkitHelper.WasDismissed(result))
			{
				return new VerbAnswer(Array.Empty<JsonElement>(), result.Message, Dismissed: true);
			}
		}
		else
		{
			result = await _shell
				.RunAsync(ScriptFor(verb, args), input ?? (verb.TakesInput ? string.Empty : null), ct)
				.ConfigureAwait(false);
		}

		return Parse(result);
	}

	/// <summary>
	/// A verb's output as objects — or the machine's sentence when it refused.
	/// </summary>
	public static VerbAnswer Parse(ShellResult result)
	{
		if (!result.Ok)
		{
			return new VerbAnswer(Array.Empty<JsonElement>(), result.Message);
		}

		var text = result.Stdout.Trim();
		if (text.Length == 0)
		{
			return new VerbAnswer(Array.Empty<JsonElement>(), null);
		}

		try
		{
			using var doc = JsonDocument.Parse(text);
			if (doc.RootElement.ValueKind != JsonValueKind.Array)
			{
				return new VerbAnswer(Array.Empty<JsonElement>(),
					"The answer was not the array every container verb returns.");
			}

			return new VerbAnswer(doc.RootElement.EnumerateArray().Select(e => e.Clone()).ToArray(), null);
		}
		catch (JsonException ex)
		{
			// The first line is what a person needs to see: it is almost always
			// a stream that reached stdout ahead of the JSON (BUILD-NOTES #60).
			var first = text.Split('\n')[0].Trim();
			return new VerbAnswer(Array.Empty<JsonElement>(),
				$"The answer could not be read ({ex.Message}). It began: {first}");
		}
	}
}
