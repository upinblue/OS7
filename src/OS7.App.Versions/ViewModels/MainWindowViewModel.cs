using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using OS7.App.Versions.Model;

namespace OS7.App.Versions.ViewModels;

/// <summary>What the window is doing.</summary>
public enum VersionsPhase
{
	Loading,
	NoHistory,
	Failed,
	Listing,
}

/// <summary>
/// One layer of the cascade: a version, and whether it is the one in front.
/// </summary>
/// <remarks>
/// <see cref="IsFront"/> selects the ACTIVE caption gradient over the inactive
/// one (VERSIONS-PLAN V12), and decides whether the layer shows its contents or
/// only its title bar. Windows 2000 used exactly that pair of colours to mean
/// "this is the one you are working in", which is what the front of a stack of
/// times means.
/// </remarks>
public sealed record CascadeLayer(VersionEntry Entry, bool IsFront);

/// <summary>One point on the timeline, and one layer of the cascade.</summary>
public sealed class VersionEntry
{
	public VersionEntry(FileVersion version) => Version = version;

	public FileVersion Version { get; }

	/// <summary>Whether this is the state the live filesystem is in.</summary>
	public bool IsCurrent => Version.IsCurrent;

	/// <summary>
	/// The caption, which is what the cascade shows of the layers behind.
	/// </summary>
	/// <remarks>
	/// ISO date and a 24-hour time, for the reason Software Update learned the
	/// hard way: a culture-formatted timestamp is ambiguous the moment it
	/// leaves the machine that wrote it. The exact format is chosen for the
	/// whole list at once — see <see cref="AssignCaptions"/>.
	/// </remarks>
	public string Caption { get; private set; } = string.Empty;

	/// <summary>
	/// Give every entry a caption, choosing one format for the whole list.
	/// </summary>
	/// <remarks>
	/// MEASURED ON A MACHINE: three snapshots taken inside one minute drew
	/// three rows reading `2026-09-14 20:39`, which is a timeline an operator
	/// cannot navigate — the rows are the thing being chosen between and they
	/// were identical. Minutes are the right resolution for hourly snapshots
	/// and the wrong one the moment anybody takes two by hand, so the list
	/// decides together: seconds appear only when they are needed, and then for
	/// every row, because a list with two formats in it is worse than either.
	/// </remarks>
	public static void AssignCaptions(IReadOnlyList<VersionEntry> entries)
	{
		const string Minutes = "yyyy-MM-dd HH:mm";
		const string Seconds = "yyyy-MM-dd HH:mm:ss";

		var times = entries
			.Where(e => !e.IsCurrent)
			.Select(e => e.Version.Created.ToLocalTime())
			.ToList();

		var collides = times
			.Select(t => t.ToString(Minutes, CultureInfo.InvariantCulture))
			.Distinct()
			.Count() != times.Count;

		var format = collides ? Seconds : Minutes;

		foreach (var entry in entries)
		{
			entry.Caption = entry.IsCurrent
				? "Now"
				: entry.Version.Created.ToLocalTime()
					.ToString(format, CultureInfo.InvariantCulture);
		}
	}

	/// <summary>What this version IS, in one phrase.</summary>
	public string State
	{
		get
		{
			if (!Version.Exists)
			{
				return "did not exist";
			}

			return Version.IsFolder ? "folder" : FormatSize(Version.Size);
		}
	}

	/// <summary>
	/// The retention bucket sanoid put the snapshot in, if it is sanoid's.
	/// </summary>
	/// <remarks>
	/// Read off the name, and used ONLY as a label — never to decide anything.
	/// A snapshot an administrator took by hand has no bucket and is shown just
	/// the same, which is the case a name-driven design would lose.
	/// </remarks>
	public string Bucket
	{
		get
		{
			var name = Version.SnapshotName;
			if (string.IsNullOrEmpty(name))
			{
				return "live";
			}

			foreach (var bucket in new[]
				{ "frequently", "hourly", "daily", "weekly", "monthly", "yearly" })
			{
				if (name.EndsWith('_' + bucket, StringComparison.Ordinal))
				{
					return bucket;
				}
			}

			return "manual";
		}
	}

	private string? _preview;
	private bool _previewed;

	/// <summary>
	/// The beginning of this version's contents, when it is text.
	/// </summary>
	/// <remarks>
	/// Read on FIRST ACCESS and then held, so a timeline of forty versions
	/// reads only the ones somebody actually looks at. A window that listed
	/// five versions and showed none of them would make the operator open each
	/// one to find the right one, which is the work they came here to avoid.
	/// </remarks>
	public string? Preview
	{
		get
		{
			if (_previewed)
			{
				return _preview;
			}

			_previewed = true;
			_preview = Version.Exists && !Version.IsFolder
				? Services.TextPreview.For(Version.SnapshotPath)
				: null;

			return _preview;
		}
	}

	public bool HasPreview => Preview is not null;

	/// <summary>What to say when there is nothing to show inline.</summary>
	public string NoPreview
	{
		get
		{
			if (!Version.Exists)
			{
				return "This file did not exist at this point.";
			}

			return Version.IsFolder
				? "A folder."
				: "Not a text file — use Open to look at it.";
		}
	}

	public static string FormatSize(long bytes)
	{
		if (bytes <= 0)
		{
			return "empty";
		}

		const double Mib = 1024 * 1024;
		const double Kib = 1024;

		return bytes >= Mib
			? $"{bytes / Mib:0.0} MiB"
			: bytes >= Kib
				? $"{bytes / Kib:0} KiB"
				: $"{bytes} bytes";
	}
}

/// <summary>
/// The window's state and its decisions.
/// </summary>
/// <remarks>
/// Constructible from a list of versions with no PowerShell behind it, which is
/// what lets <c>--self-test</c> exercise every presentation decision here. What
/// it does NOT decide is which versions exist or which are worth showing —
/// <c>Get-OS7FileVersion</c> settles both (G3).
/// </remarks>
public sealed class MainWindowViewModel : INotifyPropertyChanged
{
	/// <summary>
	/// How many layers of the cascade are drawn behind the front one.
	/// </summary>
	/// <remarks>
	/// Four, because the cascade has to read as depth without becoming a wall
	/// of title bars — a Windows 2000 MDI cascade of twenty children was
	/// already unreadable. The timeline carries the rest.
	/// </remarks>
	public const int CascadeDepth = 4;

	private VersionsPhase _phase = VersionsPhase.Loading;
	private string _message = string.Empty;
	private int _selectedIndex;

	public MainWindowViewModel(string path, IReadOnlyList<VersionEntry> entries)
	{
		Path = path;

		foreach (var entry in entries)
		{
			Entries.Add(entry);
		}

		if (entries.Count > 0)
		{
			_phase = VersionsPhase.Listing;
		}
	}

	public event PropertyChangedEventHandler? PropertyChanged;

	public string Path { get; }

	public ObservableCollection<VersionEntry> Entries { get; } = new();

	public VersionsPhase Phase
	{
		get => _phase;
		set
		{
			if (_phase == value)
			{
				return;
			}

			_phase = value;
			RaiseAll();
		}
	}

	/// <summary>The machine's own words when something went wrong.</summary>
	public string Message
	{
		get => _message;
		set
		{
			_message = value;
			Raise();
			Raise(nameof(SubHeader));
		}
	}

	/// <summary>Which point in time is selected. 0 is the newest.</summary>
	public int SelectedIndex
	{
		get => _selectedIndex;
		set
		{
			var clamped = Entries.Count == 0 ? 0 : Math.Clamp(value, 0, Entries.Count - 1);

			if (_selectedIndex == clamped)
			{
				return;
			}

			_selectedIndex = clamped;
			RaiseAll();
		}
	}

	public VersionEntry? Selected =>
		Entries.Count == 0 ? null : Entries[Math.Clamp(_selectedIndex, 0, Entries.Count - 1)];

	/// <summary>
	/// The layers of the cascade, OLDEST FIRST — which is the order
	/// <see cref="Controls.CascadePanel"/> wants, because a panel paints its
	/// children in order and the selected time has to end up in front.
	/// </summary>
	public IReadOnlyList<CascadeLayer> Cascade
	{
		get
		{
			var window = Entries.Skip(_selectedIndex).Take(CascadeDepth + 1).ToList();

			return window
				.Select((entry, i) => new CascadeLayer(entry, IsFront: i == 0))
				.Reverse()
				.ToList();
		}
	}

	public bool HasEntries => Entries.Count > 0;

	public string FileName
	{
		get
		{
			var name = System.IO.Path.GetFileName(Path.TrimEnd('/'));
			return name.Length > 0 ? name : Path;
		}
	}

	public string Header => Phase switch
	{
		VersionsPhase.Loading => "Looking for previous versions…",
		VersionsPhase.Failed => "Previous versions could not be listed.",
		VersionsPhase.NoHistory => "No previous versions are kept for this file.",
		_ => FileName,
	};

	public string SubHeader => Phase switch
	{
		VersionsPhase.Failed or VersionsPhase.NoHistory => Message,
		VersionsPhase.Loading => Path,

		// The one line that says what the history actually covers. An operator
		// deciding whether to keep looking needs the RANGE, not the count.
		_ => Oldest is null
			? Path
			: $"{Entries.Count} versions, back to "
				+ $"{Oldest.Version.Created.ToLocalTime():yyyy-MM-dd}",
	};

	public VersionEntry? Oldest => Entries.Count == 0 ? null : Entries[^1];

	/// <summary>Whether stepping further back is possible.</summary>
	public bool CanGoBack => _selectedIndex < Entries.Count - 1;

	/// <summary>Whether stepping towards now is possible.</summary>
	public bool CanGoForward => _selectedIndex > 0;

	/// <summary>
	/// Whether the selected version can be opened or copied.
	/// </summary>
	/// <remarks>
	/// A version in which the file did not exist has nothing to open, and the
	/// window must say that by disabling the verb rather than by failing when
	/// it is used. The boundary rows are exactly those.
	/// </remarks>
	public bool CanOpen => Selected?.Version is { Exists: true, IsFolder: false };

	public void GoBack() => SelectedIndex = _selectedIndex + 1;

	public void GoForward() => SelectedIndex = _selectedIndex - 1;

	private void RaiseAll()
	{
		foreach (var name in new[]
		{
			nameof(Phase), nameof(Selected), nameof(Cascade), nameof(SelectedIndex),
			nameof(CanGoBack), nameof(CanGoForward), nameof(CanOpen),
			nameof(Header), nameof(SubHeader), nameof(HasEntries), nameof(Oldest),
		})
		{
			Raise(name);
		}
	}

	private void Raise([CallerMemberName] string? name = null) =>
		PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
