using System.Collections.ObjectModel;
using System.ComponentModel;
using OS7.App.SoftwareUpdate.Model;
using OS7.App.SoftwareUpdate.Services;

namespace OS7.App.SoftwareUpdate.ViewModels;

/// <summary>What the window is doing.</summary>
public enum WindowPhase
{
	/// <summary>Asking the machine.</summary>
	Loading,

	/// <summary>The machine could not be asked, and said why.</summary>
	Failed,

	/// <summary>The list is drawn.</summary>
	Listing,

	/// <summary>An update is running.</summary>
	Installing,

	/// <summary>An update finished and the machine needs a restart.</summary>
	Finished,
}

/// <summary>
/// The window's state and its decisions.
/// </summary>
/// <remarks>
/// Constructible from a list of releases with no <see cref="Os7Cli"/> at all,
/// which is what lets <c>--self-test</c> exercise every decision here without a
/// machine, a repository, or a display. The decisions are presentation ones —
/// which sentence, which count, which button — and nothing in this class
/// decides whether a release may be installed (G3; that is
/// <see cref="ReleaseRow"/> reading the cmdlet's own flags).
/// </remarks>
public sealed class MainWindowViewModel : ViewModelBase
{
	private readonly Os7Cli? _cli;
	private readonly UpdateRunner? _runner;

	private WindowPhase _phase = WindowPhase.Loading;
	private string _error = string.Empty;
	private string _progressLine = string.Empty;
	private ReleaseRow? _selectedRow;

	/// <summary>For the real window.</summary>
	public MainWindowViewModel(Os7Cli cli)
	{
		_cli = cli;
		_runner = new UpdateRunner(cli);
	}

	/// <summary>For the self-test: a window state with no machine behind it.</summary>
	public MainWindowViewModel(IEnumerable<Os7Release> releases)
	{
		Load(releases);
	}

	public ObservableCollection<ReleaseRow> Rows { get; } = new();

	public WindowPhase Phase
	{
		get => _phase;
		private set
		{
			if (Set(ref _phase, value))
			{
				RaiseDerived();
			}
		}
	}

	/// <summary>The machine's own words when it could not be asked.</summary>
	public string Error
	{
		get => _error;
		private set => Set(ref _error, value);
	}

	public string ProgressLine
	{
		get => _progressLine;
		private set => Set(ref _progressLine, value);
	}

	public ReleaseRow? SelectedRow
	{
		get => _selectedRow;
		set
		{
			if (Set(ref _selectedRow, value))
			{
				Raise(nameof(HasSelection));
				Raise(nameof(DetailMigrations));
			}
		}
	}

	public bool HasSelection => SelectedRow is not null;

	/// <summary>
	/// The migrations a release declares, as one line. Empty when it declares
	/// none, which is the ordinary case and must not read as missing data.
	/// </summary>
	public string DetailMigrations =>
		SelectedRow?.Release.Migrations is { Count: > 0 } m
			? string.Join(", ", m)
			: "none";

	/// <summary>
	/// Whether there is a list to head with column titles.
	/// </summary>
	/// <remarks>
	/// A property rather than a value converter over <c>Rows.Count</c>. The
	/// window needs three such booleans, and three converters to turn numbers
	/// and enums into visibility is three places where the view starts making
	/// decisions the view model should be making.
	/// </remarks>
	public bool HasRows => Rows.Count > 0;

	public bool IsInstalling => Phase == WindowPhase.Installing;

	public int InstallableCount => Rows.Count(r => r.IsInstallable);

	/// <summary>
	/// Whether the channel offers anything newer than this machine at all,
	/// installable or not.
	/// </summary>
	/// <remarks>
	/// SEPARATE FROM <see cref="InstallableCount"/>, and a machine showed why.
	/// A bench pointed at a development-signed repository was offered 1.0.0.164
	/// against its own 1.0.0.163: newer, applicable, and blocked here because
	/// it is not signed for production (§3b). With the header keyed on
	/// "installable" alone the window said **"Your software is up to date"**
	/// with a newer release listed directly beneath it, and the second line
	/// then contradicted the first.
	///
	/// "Nothing newer exists" and "something newer exists that this machine
	/// will not install" are two different facts, and the cmdlet already
	/// insists on that distinction one layer down — it reports four separate
	/// reasons because "'not applicable' for four different reasons is four
	/// different conversations with the operator". A window that collapses
	/// them back into one is undoing that on purpose.
	/// </remarks>
	public bool AnythingNewer => Rows.Any(r => r.Release.Newer);

	public int SelectedCount => Rows.Count(r => r.IsSelected);

	public bool CanInstall => Phase == WindowPhase.Listing && SelectedCount > 0;

	/// <summary>
	/// The line at the top of the window.
	/// </summary>
	/// <remarks>
	/// Four states, not two. "Up to date" and "nothing could be asked" are
	/// different facts and a window that showed the first for the second would
	/// be reassuring an operator about a machine it never reached — which is
	/// the failure shape this repository names most often.
	/// </remarks>
	public string Header => Phase switch
	{
		WindowPhase.Loading => "Checking for new software…",
		WindowPhase.Failed => "This machine could not be asked about updates.",
		WindowPhase.Installing => "Installing…",
		WindowPhase.Finished => "Restart to finish installing.",
		_ when InstallableCount > 0 =>
			"New software is available for your computer.",

		// Newer software exists and this machine will not take it. Saying
		// "up to date" here would be false in the one direction that matters.
		_ when AnythingNewer =>
			"New software exists, but none of it can be installed on this computer.",

		_ => "Your software is up to date.",
	};

	/// <summary>The second line, which is where the qualification goes.</summary>
	public string SubHeader => Phase switch
	{
		WindowPhase.Failed => Error,

		WindowPhase.Finished =>
			"The new release is installed in its own boot environment. It becomes the "
			+ "running system at the next restart, and the current one stays as a way back.",

		WindowPhase.Installing => ProgressLine.Length > 0
			? ProgressLine
			: "Working…",

		_ when Rows.Count == 0 =>
			"The update channel offers nothing for this machine.",

		_ when InstallableCount == 0 =>
			"Each release below says why. Nothing here changes this machine.",

		_ => "If you don't want to install now, you can open Software Update again later.",
	};

	/// <summary>
	/// The primary button, counting what it will do, as the window this is
	/// modelled on did.
	/// </summary>
	public string InstallButtonText => SelectedCount switch
	{
		0 => "Install",
		1 => "Install 1 Item",
		var n => $"Install {n} Items",
	};

	/// <summary>
	/// Whether the restart notice is shown. It is shown whenever there is
	/// something installable, not only after installing: an operator deciding
	/// whether to start a ten-minute update needs to know it ends in a restart
	/// BEFORE they press the button.
	/// </summary>
	public bool ShowRestartNotice =>
		Phase is WindowPhase.Finished
		|| (Phase == WindowPhase.Listing && InstallableCount > 0);

	/// <summary>Fill the window from a set of releases. Used by both constructors' paths.</summary>
	public void Load(IEnumerable<Os7Release> releases)
	{
		foreach (var row in Rows)
		{
			row.PropertyChanged -= OnRowChanged;
		}

		Rows.Clear();

		// Newest first. The operator's question is "what is the latest", and a
		// repository index's order is the builder's, not an answer to that.
		foreach (var release in releases.OrderByDescending(ReleaseOrder))
		{
			var row = new ReleaseRow(release);
			row.PropertyChanged += OnRowChanged;
			Rows.Add(row);
		}

		// Pre-tick the newest installable one, and only that one. The window
		// this is modelled on arrived with everything ticked; here an update is
		// a boot environment and a restart, so the default is the single
		// obvious action rather than all of them.
		var newest = Rows.FirstOrDefault(r => r.IsInstallable);
		if (newest is not null)
		{
			newest.IsSelected = true;
		}

		SelectedRow = Rows.FirstOrDefault();
		Error = string.Empty;
		Phase = WindowPhase.Listing;
	}

	/// <summary>
	/// Versions sort as versions, never as strings.
	/// </summary>
	/// <remarks>
	/// "1.0.0.9" sorts above "1.0.0.31" as text. The update train's own
	/// self-test puts this first among its checks, calling it "the mistake this
	/// whole file is careful about"; a window that listed releases in the wrong
	/// order would pre-select the wrong one.
	/// </remarks>
	private static Version ReleaseOrder(Os7Release release) =>
		Version.TryParse(release.Version, out var parsed) ? parsed : new Version(0, 0);

	private void OnRowChanged(object? sender, PropertyChangedEventArgs e)
	{
		if (e.PropertyName == nameof(ReleaseRow.IsSelected))
		{
			RaiseDerived();
		}
	}

	private void RaiseDerived()
	{
		Raise(nameof(SelectedCount));
		Raise(nameof(InstallableCount));
		Raise(nameof(CanInstall));
		Raise(nameof(InstallButtonText));
		Raise(nameof(Header));
		Raise(nameof(SubHeader));
		Raise(nameof(ShowRestartNotice));
		Raise(nameof(HasRows));
		Raise(nameof(IsInstalling));
		Raise(nameof(AnythingNewer));
	}

	/// <summary>Ask the machine, and show whatever it says.</summary>
	public async Task RefreshAsync(CancellationToken ct = default)
	{
		if (_cli is null)
		{
			return;
		}

		Phase = WindowPhase.Loading;

		var result = await _cli.GetAvailableReleasesAsync(ct).ConfigureAwait(true);

		if (!result.Ok)
		{
			Rows.Clear();
			Error = result.Error ?? string.Empty;
			Phase = WindowPhase.Failed;
			return;
		}

		Load(result.Releases);
	}

	/// <summary>
	/// Install the ticked releases, one after another, and follow each.
	/// </summary>
	public async Task InstallSelectedAsync(CancellationToken ct = default)
	{
		if (_runner is null || !CanInstall)
		{
			return;
		}

		var chosen = Rows.Where(r => r.IsSelected).Select(r => r.Version).ToList();

		Phase = WindowPhase.Installing;

		foreach (var version in chosen)
		{
			ProgressLine = $"Starting {version}…";

			var failure = await _runner.StartAsync(version, ct).ConfigureAwait(true);
			if (failure is not null)
			{
				Error = failure;
				Phase = WindowPhase.Failed;
				return;
			}

			while (!ct.IsCancellationRequested)
			{
				await Task.Delay(TimeSpan.FromSeconds(1), ct).ConfigureAwait(true);

				var progress = await _runner.PollAsync(version, ct).ConfigureAwait(true);

				if (progress.LatestLine.Length > 0)
				{
					ProgressLine = progress.LatestLine;
				}

				if (progress.Failed)
				{
					Error = progress.LatestLine.Length > 0
						? progress.LatestLine
						: $"the update to {version} failed ({progress.Result}). "
							+ "/var/log/os7/update.log has the whole run.";
					Phase = WindowPhase.Failed;
					return;
				}

				if (progress.Succeeded)
				{
					break;
				}
			}
		}

		Phase = WindowPhase.Finished;
	}
}
