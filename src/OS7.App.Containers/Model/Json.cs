using System.Globalization;
using System.Text.Json;

namespace OS7.App.Containers.Model;

/// <summary>
/// Reading a cmdlet's object, by property name, without a type for it.
/// </summary>
/// <remarks>
/// CT11: the window has no class for a container, an image or a volume. It reads
/// the JSON the cmdlet wrote, so a property the cmdlet gains costs no C#, and a
/// property the cmdlet loses is an empty cell rather than a crash.
/// </remarks>
public static class Json
{
	public static JsonElement? Get(JsonElement item, string name)
	{
		if (item.ValueKind != JsonValueKind.Object)
		{
			return null;
		}

		foreach (var p in item.EnumerateObject())
		{
			if (string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase))
			{
				return p.Value;
			}
		}

		return null;
	}

	/// <summary>A property as text: strings as they are, arrays joined, null as empty.</summary>
	public static string Text(JsonElement item, string name)
	{
		var v = Get(item, name);
		return v is null ? string.Empty : Render(v.Value);
	}

	public static bool? Bool(JsonElement item, string name)
	{
		var v = Get(item, name);
		return v?.ValueKind switch
		{
			JsonValueKind.True => true,
			JsonValueKind.False => false,
			_ => null,
		};
	}

	public static long? Long(JsonElement item, string name)
	{
		var v = Get(item, name);
		if (v is { ValueKind: JsonValueKind.Number } n && n.TryGetInt64(out var l))
		{
			return l;
		}

		return null;
	}

	public static IReadOnlyList<string> Strings(JsonElement item, string name)
	{
		var v = Get(item, name);
		if (v is not { ValueKind: JsonValueKind.Array } a)
		{
			var one = v is null ? string.Empty : Render(v.Value);
			return one.Length == 0 ? Array.Empty<string>() : new[] { one };
		}

		return a.EnumerateArray().Select(Render).Where(s => s.Length > 0).ToArray();
	}

	/// <summary>Any value, as one line of text.</summary>
	public static string Render(JsonElement v) => v.ValueKind switch
	{
		JsonValueKind.String => v.GetString() ?? string.Empty,
		JsonValueKind.Number => v.GetRawText(),
		JsonValueKind.True => "Yes",
		JsonValueKind.False => "No",
		JsonValueKind.Array => string.Join(", ", v.EnumerateArray().Select(Render).Where(s => s.Length > 0)),
		JsonValueKind.Object => string.Join("; ", v.EnumerateObject().Select(p => $"{p.Name} = {Render(p.Value)}")),
		_ => string.Empty,
	};

	/// <summary>Bytes as a person reads them. The number itself is the cmdlet's.</summary>
	public static string Size(long? bytes)
	{
		if (bytes is null || bytes < 0)
		{
			return string.Empty;
		}

		string[] units = { "B", "KiB", "MiB", "GiB", "TiB" };
		double value = bytes.Value;
		var unit = 0;
		while (value >= 1024 && unit < units.Length - 1)
		{
			value /= 1024;
			unit++;
		}

		return unit == 0
			? string.Create(CultureInfo.InvariantCulture, $"{bytes} B")
			: string.Create(CultureInfo.InvariantCulture, $"{value:0.0} {units[unit]}");
	}
}
