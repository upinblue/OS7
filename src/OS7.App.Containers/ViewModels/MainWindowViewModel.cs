using System.Collections.ObjectModel;
using System.Text.Json;
using OS7.App.Containers.Model;
using OS7.App.Containers.Services;

namespace OS7.App.Containers.ViewModels;

/// <summary>Whether the window may show the engine's contents yet.</summary>
public enum AccessState
{
	Asking,
	Ready,
	NeedsSignIn,
	NoEngine,
	Failed,
}

/// <summary>
/// The Containers window: a tree, a list, the selected object's properties and
/// a status line (CONTAINERS-PLAN CT9).
/// </summary>
/// <remarks>
/// <para>
/// IT ASKS FIRST, AND ONLY THEN DRAWS. <c>Get-OS7ContainerHost</c> answers any
/// account — that is its contract — and says whether this session may talk to
/// the engine: Root and Operator draw the engine at once, Denied draws the
/// frame and the one sentence CT5 asks for, with Sign in…; NoEngine draws the
/// cmdlet that installs one. This is G6 bent for a measured reason and then
/// kept: the prompt appears at the moment it can be explained.
/// </para>
/// <para>
/// IT DOES NOT POLL (G10). The list is asked again on F5, on Refresh and after
/// the window's own actions — never on a timer.
/// </para>
/// </remarks>
public sealed class MainWindowViewModel : ViewModelBase
{
	private NodeItem? _selectedNode;
	private ObjectRow? _selectedRow;
	private string _message = "Asking the container engine…";
	private string _status = string.Empty;
	private string _actionResult = string.Empty;
	private bool _busy;
	private AccessState _access = AccessState.Asking;
	private JsonElement? _host;
	private IReadOnlyList<Column> _columns = Columns.For(NodeKind.Overview);

	public MainWindowViewModel(ContainerChannel? channel = null)
	{
		Channel = channel ?? new ContainerChannel();
		foreach (var kind in Enum.GetValues<NodeKind>())
		{
			Nodes.Add(new NodeItem(kind));
		}
	}

	public ContainerChannel Channel { get; }

	public ObservableCollection<NodeItem> Nodes { get; } = new();

	public ObservableCollection<ObjectRow> Rows { get; } = new();

	public ObservableCollection<PropertyRow> Details { get; } = new();

	public NodeItem? SelectedNode
	{
		get => _selectedNode;
		set
		{
			if (Set(ref _selectedNode, value) && value is not null)
			{
				ActionResult = string.Empty;
				_columns = Columns.For(value.Kind);
				RaiseState();
				_ = LoadNodeAsync(value);
			}
		}
	}

	public ObjectRow? SelectedRow
	{
		get => _selectedRow;
		set
		{
			if (Set(ref _selectedRow, value))
			{
				ShowDetails(value?.Item ?? _host);
				RaiseState();
			}
		}
	}

	public string Message
	{
		get => _message;
		set { if (Set(ref _message, value)) { Raise(nameof(ShowMessage)); } }
	}

	public string Status
	{
		get => _status;
		set => Set(ref _status, value);
	}

	/// <summary>What the last action said — the cmdlet's outcome and state, or its refusal.</summary>
	public string ActionResult
	{
		get => _actionResult;
		set { if (Set(ref _actionResult, value)) { Raise(nameof(ShowActionResult)); } }
	}

	public bool ShowActionResult => ActionResult.Length > 0;

	public bool Busy
	{
		get => _busy;
		set { if (Set(ref _busy, value)) { RaiseState(); } }
	}

	public AccessState Access
	{
		get => _access;
		set { if (Set(ref _access, value)) { RaiseState(); } }
	}

	public NodeKind Kind => _selectedNode?.Kind ?? NodeKind.Overview;

	public string Heading => Columns.Title(Kind);

	public string Header0 => Header(0);
	public string Header1 => Header(1);
	public string Header2 => Header(2);
	public string Header3 => Header(3);
	public string Header4 => Header(4);

	public bool ShowMessage => Message.Length > 0;
	public bool ShowSignIn => Access == AccessState.NeedsSignIn && !Busy;

	/// <summary>
	/// The engine is not installed, and the window may offer to install it —
	/// which Get-OS7ContainerHost said, not this window (Access = NoEngine).
	/// </summary>
	public bool ShowInstall => Access == AccessState.NoEngine && !Busy;
	public bool Ready => Access == AccessState.Ready && !Busy;
	public bool HasSelection => _selectedRow is not null;
	public bool CanAct => Ready && HasSelection;

	public bool IsContainerNode => Kind is NodeKind.Overview or NodeKind.Containers;
	public bool IsApplicationNode => Kind == NodeKind.Applications;
	public bool IsImageNode => Kind == NodeKind.Images;
	public bool IsVolumeNode => Kind == NodeKind.Volumes;
	public bool IsNetworkNode => Kind == NodeKind.Networks;

	/// <summary>
	/// Removing is offered only where the engine would do it: not for its own
	/// three networks, which it refuses (403). Read off the cmdlet's Builtin,
	/// not decided here.
	/// </summary>
	public bool CanRemoveNetwork => CanAct && _selectedRow is { } r && Json.Bool(r.Item, "Builtin") != true;

	private string Header(int i) => i < _columns.Count ? _columns[i].Header : string.Empty;

	private void RaiseState()
	{
		foreach (var name in new[]
		{
			nameof(Kind), nameof(Heading), nameof(Header0), nameof(Header1), nameof(Header2), nameof(Header3),
			nameof(Header4), nameof(ShowSignIn), nameof(ShowInstall), nameof(Ready), nameof(HasSelection), nameof(CanAct),
			nameof(IsContainerNode), nameof(IsApplicationNode), nameof(IsImageNode), nameof(IsVolumeNode),
			nameof(IsNetworkNode), nameof(CanRemoveNetwork),
		})
		{
			Raise(name);
		}
	}

	/// <summary>How the host's answer decides what the window may do.</summary>
	public static AccessState AccessFrom(string access) => access switch
	{
		"Root" or "Operator" => AccessState.Ready,
		"Denied" => AccessState.NeedsSignIn,
		"NoEngine" => AccessState.NoEngine,
		_ => AccessState.Failed,
	};

	/// <summary>The status line, from Get-OS7ContainerHost's own fields.</summary>
	public static string StatusLine(JsonElement host, ChannelMode mode)
	{
		var parts = new List<string>();
		var version = Json.Text(host, "EngineVersion");
		if (version.Length > 0)
		{
			parts.Add($"Docker {version}, API {Json.Text(host, "ApiVersion")}");
		}

		if (Json.Long(host, "Containers") is { } total)
		{
			parts.Add($"{Json.Long(host, "ContainersRunning") ?? 0} of {total} containers running");
		}

		if (Json.Long(host, "ContainersNeedingAttention") is long attention && attention > 0)
		{
			parts.Add($"{attention} need attention");
		}

		if (Json.Long(host, "PoolCapacity") is { } capacity)
		{
			parts.Add($"pool {Json.Text(host, "Pool")} {capacity}% full ({Json.Text(host, "PoolLevel")})");
		}

		parts.Add(mode == ChannelMode.Helper
			? "signed in through polkit"
			: Json.Text(host, "Access") switch
			{
				"Root" => "as root",
				"Operator" => "as a container operator",
				_ => "not signed in",
			});

		return string.Join("  ·  ", parts);
	}

	/// <summary>What an empty list means, in each node.</summary>
	public static string EmptySentence(NodeKind kind) => kind switch
	{
		NodeKind.Overview => "No container needs attention. Containers lists every one.",
		NodeKind.Containers => "There are no containers on this machine. New container… creates one.",
		NodeKind.Applications => "No container here carries a Compose project's label.",
		NodeKind.Images => "There are no images on this machine.",
		NodeKind.Volumes => "There are no volumes on this machine.",
		NodeKind.Networks => "The engine reports no networks.",
		_ => string.Empty,
	};

	/// <summary>One action's answer as the line under the list.</summary>
	public static string Summarise(string what, VerbAnswer answer)
	{
		if (!answer.Ok)
		{
			return answer.Dismissed ? $"{what}: not done — the authentication dialog was closed." : answer.Error!;
		}

		var lines = answer.Items.Select(i =>
		{
			var name = Json.Text(i, "Name");
			var outcome = Json.Text(i, "Outcome");
			var state = Json.Text(i, "State");
			var reason = Json.Text(i, "Reason");
			var line = name.Length > 0 ? $"{name}: {outcome}" : outcome;
			if (state.Length > 0 && state != outcome)
			{
				line += $", now {state}";
			}

			return reason.Length > 0 ? $"{line}. {reason}" : line;
		}).Where(l => l.Trim().Length > 0).ToArray();

		return lines.Length == 0 ? $"{what}: done." : string.Join(Environment.NewLine, lines);
	}

	public async Task StartAsync()
	{
		await AskHostAsync().ConfigureAwait(true);
		if (Access == AccessState.Ready)
		{
			SelectedNode = Nodes[0];
		}
	}

	/// <summary>
	/// Make this machine a container host — Install-OS7ContainerHost through
	/// its own helper — and then work through the operate helper, because the
	/// account that just installed the engine is not in the socket's group.
	/// </summary>
	public async Task<VerbAnswer> InstallHostAsync()
	{
		Message = "Setting up the container engine: its datasets first, then its packages from the Ubuntu archive. This takes a few minutes.";
		var answer = await RunAsync("Set up the engine", ContainerVerbs.InstallHost).ConfigureAwait(true);
		if (answer.Ok)
		{
			ActionResult = InstallSummary(answer);
			await SignInAsync().ConfigureAwait(true);
		}
		else
		{
			// Asked again, because a setup that failed half-way has changed the
			// machine — the datasets come first and the archive last (CT3) — and
			// the properties must say what is there NOW. The refusal stays on
			// screen in the cmdlet's words.
			await AskHostAsync().ConfigureAwait(true);
			if (!answer.Dismissed)
			{
				Message = answer.Error!;
			}
		}

		return answer;
	}

	/// <summary>Install-OS7ContainerHost's own read-backs, as one line each.</summary>
	public static string InstallSummary(VerbAnswer answer)
	{
		if (answer.First is not { } r)
		{
			return "Set up the engine: done.";
		}

		var lines = new List<string>
		{
			$"{Json.Text(r, "Outcome")}: Docker {Json.Text(r, "Engine")} ({Json.Text(r, "Packages")}).",
		};
		if (Json.Get(r, "Checks") is { ValueKind: JsonValueKind.Array } checks)
		{
			lines.AddRange(checks.EnumerateArray().Select(c =>
				$"{(Json.Bool(c, "Ok") == true ? "ok" : "NOT")}  {Json.Text(c, "Check")}"));
		}

		return string.Join(Environment.NewLine, lines);
	}

	/// <summary>Sign in through polkit: the helper, as root, from now on.</summary>
	public async Task SignInAsync()
	{
		Channel.Mode = ChannelMode.Helper;
		await AskHostAsync().ConfigureAwait(true);
		if (Access != AccessState.Ready)
		{
			Channel.Mode = ChannelMode.Direct;
			if (Access is AccessState.Failed or AccessState.Asking)
			{
				Access = AccessState.NeedsSignIn;
			}

			return;
		}

		if (SelectedNode is null)
		{
			SelectedNode = Nodes[0];
		}
		else
		{
			await LoadNodeAsync(SelectedNode).ConfigureAwait(true);
		}
	}

	public async Task RefreshAsync()
	{
		await AskHostAsync().ConfigureAwait(true);
		if (Access != AccessState.Ready)
		{
			return;
		}

		if (SelectedNode is null)
		{
			SelectedNode = Nodes[0];
		}
		else
		{
			await LoadNodeAsync(SelectedNode).ConfigureAwait(true);
		}
	}

	/// <summary>Run one verb for an action, and say what it answered under the list.</summary>
	public async Task<VerbAnswer> RunAsync(string what, ContainerVerb verb, IReadOnlyList<string>? arguments = null, string? input = null)
	{
		Busy = true;
		try
		{
			var answer = await Channel.RunAsync(verb, arguments, input).ConfigureAwait(true);
			ActionResult = Summarise(what, answer);
			return answer;
		}
		finally
		{
			Busy = false;
		}
	}

	/// <summary>Run one verb for a dialog, without touching the window's state line.</summary>
	public async Task<VerbAnswer> AskAsync(ContainerVerb verb, IReadOnlyList<string>? arguments = null, string? input = null)
	{
		Busy = true;
		try
		{
			return await Channel.RunAsync(verb, arguments, input).ConfigureAwait(true);
		}
		finally
		{
			Busy = false;
		}
	}

	private async Task AskHostAsync()
	{
		Busy = true;
		try
		{
			var answer = await Channel.RunAsync(ContainerVerbs.Host).ConfigureAwait(true);
			if (!answer.Ok || answer.First is not { } host)
			{
				Access = answer.Dismissed ? AccessState.NeedsSignIn : AccessState.Failed;
				Message = answer.Error ?? "Get-OS7ContainerHost answered nothing.";
				return;
			}

			_host = host;
			Status = StatusLine(host, Channel.Mode);
			Access = AccessFrom(Json.Text(host, "Access"));
			var reason = Json.Text(host, "Reason");
			var command = Json.Text(host, "Command");
			Message = Access switch
			{
				AccessState.NeedsSignIn => $"{reason}{Environment.NewLine}{Environment.NewLine}Sign in… asks for an administrator's password in polkit's own dialog.",
				AccessState.NoEngine => $"{reason}{Environment.NewLine}{Environment.NewLine}Set up the engine… does it from here, or in a terminal:{Environment.NewLine}{Environment.NewLine}    {command}",
				AccessState.Failed => reason.Length > 0 ? reason : $"Get-OS7ContainerHost answered '{Json.Text(host, "Access")}'.",
				_ => string.Empty,
			};

			var overview = Nodes.First(n => n.Kind == NodeKind.Overview);
			overview.Count = Json.Long(host, "ContainersNeedingAttention") is long n && n > 0
				? n.ToString(System.Globalization.CultureInfo.InvariantCulture)
				: string.Empty;

			if (Access != AccessState.Ready)
			{
				Rows.Clear();
				ShowDetails(host);
			}
		}
		finally
		{
			Busy = false;
		}
	}

	private async Task LoadNodeAsync(NodeItem node)
	{
		if (Access != AccessState.Ready)
		{
			return;
		}

		Busy = true;
		try
		{
			Rows.Clear();
			SelectedRow = null;
			IReadOnlyList<JsonElement> items;

			if (node.Kind == NodeKind.Engine)
			{
				items = _host is { } h ? new[] { h } : Array.Empty<JsonElement>();
				Message = string.Empty;
			}
			else
			{
				var answer = await Channel.RunAsync(Columns.VerbFor(node.Kind)).ConfigureAwait(true);
				if (!answer.Ok)
				{
					Message = answer.Error!;
					return;
				}

				items = answer.Items;
			}

			foreach (var item in items)
			{
				Rows.Add(new ObjectRow(node.Kind, item));
			}

			Message = Rows.Count == 0 ? EmptySentence(node.Kind) : string.Empty;
			if (node.Kind != NodeKind.Overview)
			{
				node.Count = Rows.Count.ToString(System.Globalization.CultureInfo.InvariantCulture);
			}

			ShowDetails(_host);
		}
		finally
		{
			Busy = false;
		}
	}

	private void ShowDetails(JsonElement? item)
	{
		Details.Clear();
		if (item is { } i)
		{
			foreach (var row in PropertyGrid.Render(i))
			{
				Details.Add(row);
			}
		}
	}
}
