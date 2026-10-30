using System.Text.Json;

namespace OS7.App.Containers.ViewModels;

/// <summary>
/// The create dialog's fields, turned into the description New-OS7Container
/// reads. It splits text into lines and NOTHING MORE.
/// </summary>
/// <remarks>
/// <para>
/// WHAT IS NOT HERE: whether a port is a port, a volume a volume, a name free
/// or an image present. Those are <c>New-OS7Container -ValidateOnly</c>'s, and
/// the dialog shows its answer — so an administrator who types the same
/// description at a shell gets the same refusals in the same words (G7).
/// </para>
/// <para>
/// The one convenience is "only this machine": Docker's own syntax opens a port
/// with no address on EVERY network, and the dialog's checkbox, on by default,
/// writes 127.0.0.1 in front of a port that names no address. The plan the
/// cmdlet returns then says "this machine only" in its own words, so nobody has
/// to trust this sentence.
/// </para>
/// </remarks>
public static class CreateForm
{
	public const string Loopback = "127.0.0.1";

	public static IReadOnlyList<string> Lines(string? text) =>
		(text ?? string.Empty)
			.Split('\n')
			.Select(l => l.Trim())
			.Where(l => l.Length > 0)
			.ToArray();

	/// <summary>The ports as typed, with 127.0.0.1 in front of those that name no address.</summary>
	public static IReadOnlyList<string> Ports(string? text, bool thisMachineOnly)
	{
		return Lines(text).Select(line =>
		{
			if (!thisMachineOnly || line.StartsWith('['))
			{
				return line;
			}

			var beforeProtocol = line.Split('/')[0];
			return beforeProtocol.Split(':').Length == 2 ? $"{Loopback}:{line}" : line;
		}).ToArray();
	}

	/// <summary>
	/// The environment, one NAME=value per line. A line with no '=' is said back
	/// rather than guessed at: Docker reads a bare NAME as "copy it from the
	/// caller's environment", which from a dialog would be this window's.
	/// </summary>
	public static (IReadOnlyDictionary<string, string> Values, IReadOnlyList<string> Problems) Environment(string? text)
	{
		var values = new SortedDictionary<string, string>(StringComparer.Ordinal);
		var problems = new List<string>();
		var n = 0;
		foreach (var line in (text ?? string.Empty).Split('\n'))
		{
			n++;
			var l = line.TrimEnd('\r');
			if (l.Trim().Length == 0)
			{
				continue;
			}

			var eq = l.IndexOf('=');
			if (eq <= 0)
			{
				problems.Add($"Environment line {n} is not NAME=value.");
				continue;
			}

			values[l[..eq].Trim()] = l[(eq + 1)..];
		}

		return (values, problems);
	}

	/// <summary>The description, as New-OS7Container's verb reads it on standard input.</summary>
	public static string ToJson(
		string name,
		string image,
		IReadOnlyList<string> ports,
		IReadOnlyList<string> volumes,
		IReadOnlyDictionary<string, string> environment,
		bool restartAutomatically,
		bool start)
	{
		return JsonSerializer.Serialize(new Dictionary<string, object>
		{
			["Name"] = name.Trim(),
			["Image"] = image.Trim(),
			["Port"] = ports,
			["Volume"] = volumes,
			["Environment"] = environment,
			["RestartPolicy"] = restartAutomatically ? "unless-stopped" : "no",
			["NoStart"] = !start,
		});
	}
}
