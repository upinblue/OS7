using System.Text.Json;
using OS7.App.Containers.Model;
using OS7.App.Containers.Services;

namespace OS7.App.Containers.ViewModels;

/// <summary>The tree on the left — Computer Management's, for one engine (CT9).</summary>
public enum NodeKind
{
	Overview,
	Containers,
	Applications,
	Images,
	Volumes,
	Networks,
	Engine,
}

/// <summary>One column of the list: a header, and how a row's cell is read.</summary>
public sealed record Column(string Header, Func<JsonElement, string> Cell);

/// <summary>
/// THE ONLY PLACE PROPERTY NAMES ARE WRITTEN IN THIS APPLICATION (CT11). The
/// list shows five columns per node and names them here; everything else is the
/// details pane, which renders whatever the cmdlet sent.
/// </summary>
public static class Columns
{
	public const int Count = 5;

	public static string Title(NodeKind kind) => kind switch
	{
		NodeKind.Overview => "Needs attention",
		NodeKind.Containers => "Containers",
		NodeKind.Applications => "Applications",
		NodeKind.Images => "Images",
		NodeKind.Volumes => "Volumes",
		NodeKind.Networks => "Networks",
		NodeKind.Engine => "Engine",
		_ => kind.ToString(),
	};

	/// <summary>Which verb fills a node's list.</summary>
	public static ContainerVerb VerbFor(NodeKind kind) => kind switch
	{
		NodeKind.Overview => ContainerVerbs.Attention,
		NodeKind.Containers => ContainerVerbs.List,
		NodeKind.Applications => ContainerVerbs.Apps,
		NodeKind.Images => ContainerVerbs.Images,
		NodeKind.Volumes => ContainerVerbs.Volumes,
		NodeKind.Networks => ContainerVerbs.Networks,
		_ => ContainerVerbs.Host,
	};

	/// <summary>The property a row is NAMED by — what an action is given.</summary>
	public static string NameOf(NodeKind kind, JsonElement item) => kind switch
	{
		NodeKind.Images => Json.Text(item, "Name") is { } n && n.StartsWith("<none>", StringComparison.Ordinal)
			? Json.Text(item, "Id")
			: Json.Text(item, "Name"),
		_ => Json.Text(item, "Name"),
	};

	public static IReadOnlyList<Column> For(NodeKind kind) => kind switch
	{
		NodeKind.Overview => new Column[]
		{
			new("Name", i => Json.Text(i, "Name")),
			new("State", i => Json.Text(i, "State")),
			new("What is wrong", i => Json.Text(i, "Reason")),
			new("Image", i => Json.Text(i, "Image")),
			new("Restart policy", i => Json.Text(i, "RestartPolicy")),
		},
		NodeKind.Containers => new Column[]
		{
			new("Name", i => Json.Text(i, "Name")),
			new("State", i => Json.Text(i, "State")),
			new("Image", i => Json.Text(i, "Image")),
			new("Reachable", i => Json.Text(i, "Reachable")),
			new("Restart policy", i => Json.Text(i, "RestartPolicy")),
		},
		NodeKind.Applications => new Column[]
		{
			new("Name", i => Json.Text(i, "Name")),
			new("State", i => Json.Text(i, "State")),
			new("Running", i => $"{Json.Text(i, "Running")} of {Json.Text(i, "Total")}"),
			new("Services", i => Json.Text(i, "Services")),
			new("Folder", i => Json.Text(i, "WorkingDirectory")),
		},
		NodeKind.Images => new Column[]
		{
			new("Name", i => Json.Text(i, "Name")),
			new("Size", i => Json.Size(Json.Long(i, "Size"))),
			new("Used by", i => Json.Text(i, "UsedBy")),
			new("Registry", Update),
			new("Created", i => When(Json.Text(i, "Created"))),
		},
		NodeKind.Volumes => new Column[]
		{
			new("Name", i => Json.Text(i, "Name")),
			new("Size", i => Json.Size(Json.Long(i, "Size"))),
			new("Used by", i => Json.Text(i, "UsedBy")),
			new("Backed up", i => Json.Bool(i, "BackedUp") switch { true => "Yes", false => "No", null => "Unknown" }),
			new("Newest snapshot", i => When(Json.Text(i, "LatestSnapshot"))),
		},
		NodeKind.Networks => new Column[]
		{
			new("Name", i => Json.Text(i, "Name")),
			new("Driver", i => Json.Text(i, "Driver")),
			new("Subnet", i => Json.Text(i, "Subnet")),
			new("Used by", i => Json.Text(i, "UsedBy")),
			new("Built in", i => Json.Bool(i, "Builtin") == true ? "Yes" : string.Empty),
		},
		_ => new Column[]
		{
			new("Docker", i => Json.Text(i, "EngineVersion")),
			new("Access", i => Json.Text(i, "Access")),
			new("Store", i => Json.Text(i, "Layout")),
			new("Pool", i => Json.Long(i, "PoolCapacity") is { } c ? $"{c}% ({Json.Text(i, "PoolLevel")})" : string.Empty),
			new("Bridge", i => Json.Text(i, "Bridge")),
		},
	};

	/// <summary>
	/// The registry column: the cmdlet's three outcomes, and whether it was
	/// asked at all — never a fourth answer made up here.
	/// </summary>
	public static string Update(JsonElement item)
	{
		if (Json.Bool(item, "UpdateChecked") != true)
		{
			return string.Empty;
		}

		return Json.Bool(item, "UpdateAvailable") switch
		{
			true => "Newer image available",
			false => "Current",
			null => "Could not be checked",
		};
	}

	/// <summary>A timestamp as a person reads it: date and minute, no zone noise.</summary>
	public static string When(string text)
	{
		if (DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture,
				System.Globalization.DateTimeStyles.AssumeUniversal, out var t))
		{
			return t.ToLocalTime().ToString("yyyy-MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture);
		}

		return text;
	}
}

/// <summary>A node of the tree.</summary>
public sealed class NodeItem : ViewModelBase
{
	private string _count = string.Empty;

	public NodeItem(NodeKind kind) => Kind = kind;

	public NodeKind Kind { get; }

	public string Title => Columns.Title(Kind);

	public string Count
	{
		get => _count;
		set => Set(ref _count, value);
	}
}

/// <summary>One row of the list: the cmdlet's object, and its five cells.</summary>
public sealed class ObjectRow
{
	public ObjectRow(NodeKind kind, JsonElement item)
	{
		Kind = kind;
		Item = item;
		var columns = Columns.For(kind);
		var cells = columns.Select(c => c.Cell(item)).ToArray();
		C0 = cells.ElementAtOrDefault(0) ?? string.Empty;
		C1 = cells.ElementAtOrDefault(1) ?? string.Empty;
		C2 = cells.ElementAtOrDefault(2) ?? string.Empty;
		C3 = cells.ElementAtOrDefault(3) ?? string.Empty;
		C4 = cells.ElementAtOrDefault(4) ?? string.Empty;
		Name = Columns.NameOf(kind, item);
		NeedsAttention = Json.Bool(item, "NeedsAttention") == true;
	}

	public NodeKind Kind { get; }

	public JsonElement Item { get; }

	public string Name { get; }

	public bool NeedsAttention { get; }

	public string C0 { get; }

	public string C1 { get; }

	public string C2 { get; }

	public string C3 { get; }

	public string C4 { get; }
}
