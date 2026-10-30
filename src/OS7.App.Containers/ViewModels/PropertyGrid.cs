using System.Text;
using System.Text.Json;
using OS7.App.Containers.Model;

namespace OS7.App.Containers.ViewModels;

/// <summary>One line of the details pane.</summary>
public sealed record PropertyRow(string Label, string Value);

/// <summary>
/// The details pane: the cmdlet's object, property by property (CT11).
/// </summary>
/// <remarks>
/// <para>
/// THERE IS NO LIST OF PROPERTIES HERE. Whatever the cmdlet sent is shown, in
/// the order it sent it, under its own name made readable — <c>NeedsAttention</c>
/// becomes "Needs attention" mechanically, and a handful of words that do not
/// split well are spelled out below. A property `Get-OS7Container` gains next
/// release appears here with no change to this file, which is the half of
/// "easy to keep up to date" the window can deliver.
/// </para>
/// <para>
/// What it does NOT render is a container's environment, and that is not a
/// filter here: the cmdlet never sends one (M-CT6), so there is nothing to
/// filter.
/// </para>
/// </remarks>
public static class PropertyGrid
{
	private static readonly Dictionary<string, string> Words = new(StringComparer.Ordinal)
	{
		["Id"] = "ID",
		["ApiVersion"] = "API version",
		["UsedBy"] = "Used by",
		["InUse"] = "In use",
		["PortsConfigured"] = "Ports configured",
		["RepoDigests"] = "Registry digests",
		["RemoteDigest"] = "Registry digest now",
	};

	public static IReadOnlyList<PropertyRow> Render(JsonElement item)
	{
		var rows = new List<PropertyRow>();
		if (item.ValueKind != JsonValueKind.Object)
		{
			return rows;
		}

		foreach (var p in item.EnumerateObject())
		{
			rows.Add(new PropertyRow(Label(p.Name), Value(p.Name, p.Value)));
		}

		return rows;
	}

	/// <summary>A property name as a label.</summary>
	public static string Label(string name)
	{
		if (Words.TryGetValue(name, out var word))
		{
			return word;
		}

		var b = new StringBuilder();
		for (var i = 0; i < name.Length; i++)
		{
			var c = name[i];
			if (i > 0 && char.IsUpper(c) && !char.IsUpper(name[i - 1]))
			{
				b.Append(' ');
				b.Append(char.ToLowerInvariant(c));
			}
			else
			{
				b.Append(c);
			}
		}

		return b.ToString();
	}

	/// <summary>A value as the pane shows it. Null is a dash, never an empty line.</summary>
	public static string Value(string name, JsonElement v)
	{
		switch (v.ValueKind)
		{
			case JsonValueKind.Null:
			case JsonValueKind.Undefined:
				return "—";
			case JsonValueKind.Number when name.EndsWith("Size", StringComparison.Ordinal) && v.TryGetInt64(out var bytes):
				return $"{Json.Size(bytes)} ({bytes} bytes)";
			case JsonValueKind.Array:
				var items = v.EnumerateArray().ToArray();
				if (items.Length == 0)
				{
					return "—";
				}

				// An array of objects — a container's ports, a volume's
				// versions — one per line; of values, one line. An object that
				// carries a Text is shown BY it: the cmdlet wrote that sentence
				// for a person (CT8's "8080 → 80/tcp · this machine only"), and
				// its fields beside it are for a script.
				return items.Any(x => x.ValueKind == JsonValueKind.Object)
					? string.Join(Environment.NewLine, items.Select(x =>
						Json.Get(x, "Text") is { ValueKind: JsonValueKind.String } t ? t.GetString() ?? string.Empty : Json.Render(x)))
					: Json.Render(v);
			case JsonValueKind.Object:
				var lines = v.EnumerateObject().Select(p => $"{p.Name} = {Json.Render(p.Value)}").ToArray();
				return lines.Length == 0 ? "—" : string.Join(Environment.NewLine, lines);
			default:
				var text = Json.Render(v);
				return text.Length == 0 ? "—" : text;
		}
	}
}
