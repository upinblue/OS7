using Avalonia.Controls;
using Avalonia.Input;
using OS7.App.Containers.Model;
using OS7.App.Containers.Services;
using OS7.App.Containers.ViewModels;

namespace OS7.App.Containers.Views;

public partial class MainWindow : Window
{
	public MainWindow()
	{
		// InitializeComponent() IS GENERATED. Writing one here compiles, loads
		// the XAML, and leaves every x:Name'd field null — BUILD-NOTES #152.
		InitializeComponent();

		RefreshButton.Click += async (_, _) => await Run(m => m.RefreshAsync());
		SignInButton.Click += async (_, _) => await Run(m => m.SignInAsync());
		InstallButton.Click += async (_, _) => await InstallHost();

		StartButton.Click += async (_, _) => await Act("Start", ContainerVerbs.Start);
		StopButton.Click += async (_, _) => await Act("Stop", ContainerVerbs.Stop);
		RestartButton.Click += async (_, _) => await Act("Restart", ContainerVerbs.Restart);
		LogButton.Click += async (_, _) => await ShowLog();
		RemoveButton.Click += async (_, _) => await RemoveContainer();
		NewButton.Click += async (_, _) => await NewContainer();

		AppStartButton.Click += async (_, _) => await Act("Start application", ContainerVerbs.AppStart);
		AppStopButton.Click += async (_, _) => await Act("Stop application", ContainerVerbs.AppStop);

		CheckUpdatesButton.Click += async (_, _) => await CheckUpdates();
		ImageRemoveButton.Click += async (_, _) => await Remove(ContainerVerbs.ImageRemove,
			"Remove image {0}? It can be pulled again; a container that uses it is refused by the engine.");

		VersionsButton.Click += async (_, _) => await ShowVolumeVersions();
		VolumeRemoveButton.Click += async (_, _) => await Remove(ContainerVerbs.VolumeRemove,
			"Remove volume {0} AND THE DATA IN IT? What the snapshots of the engine's dataset still hold is all that will be left.");

		NetworkRemoveButton.Click += async (_, _) => await Remove(ContainerVerbs.NetworkRemove,
			"Remove network {0}?");

		CleanupButton.Click += async (_, _) => await CleanUp();

		KeyDown += async (_, e) =>
		{
			if (e.Key == Key.F5)
			{
				e.Handled = true;
				await Run(m => m.RefreshAsync());
			}
		};
	}

	private MainWindowViewModel? Model => DataContext as MainWindowViewModel;

	private async Task Run(Func<MainWindowViewModel, Task> work)
	{
		if (Model is { } m)
		{
			await work(m);
		}
	}

	/// <summary>One verb on the selected row, then the list again.</summary>
	private async Task Act(string what, ContainerVerb verb)
	{
		if (Model is not { SelectedRow: { } row } m)
		{
			return;
		}

		await m.RunAsync(what, verb, new[] { row.Name });
		await m.RefreshAsync();
	}

	private async Task Remove(ContainerVerb verb, string question)
	{
		if (Model is not { SelectedRow: { } row } m)
		{
			return;
		}

		if (!await Dialogs.ConfirmAsync(this, "Remove", string.Format(System.Globalization.CultureInfo.InvariantCulture, question, row.Name), "Remove"))
		{
			return;
		}

		await m.RunAsync("Remove", verb, new[] { row.Name });
		await m.RefreshAsync();
	}

	/// <summary>
	/// Removing a container: what the cmdlet will keep is said BEFORE the
	/// question, from the container's own Volumes, because "its named volumes
	/// stay" is the sentence that decides whether somebody presses the button.
	/// </summary>
	private async Task RemoveContainer()
	{
		if (Model is not { SelectedRow: { } row } m)
		{
			return;
		}

		var volumes = Json.Strings(row.Item, "Volumes");
		var running = Json.Text(row.Item, "State") is "Running" or "Starting" or "Unhealthy" or "RestartLoop";
		var question =
			$"Remove container {row.Name}?{Environment.NewLine}{Environment.NewLine}"
			+ "What it wrote outside its volumes is deleted, and is not in any backup."
			+ (volumes.Count > 0 ? $" Its volumes stay: {string.Join(", ", volumes)}." : string.Empty)
			+ (running ? $"{Environment.NewLine}{Environment.NewLine}It is running, and will be stopped first." : string.Empty);

		if (!await Dialogs.ConfirmAsync(this, "Remove container", question, "Remove"))
		{
			return;
		}

		var args = running ? new[] { row.Name, "force" } : new[] { row.Name };
		await m.RunAsync("Remove", ContainerVerbs.Remove, args);
		await m.RefreshAsync();
	}

	private async Task ShowLog()
	{
		if (Model is not { SelectedRow: { } row } m)
		{
			return;
		}

		var answer = await m.AskAsync(ContainerVerbs.Log, new[] { row.Name, "300" });
		var text = answer.Ok
			? string.Join(Environment.NewLine, answer.Items.Select(l =>
				(Json.Text(l, "Stream") == "stderr" ? "! " : "  ") + Json.Text(l, "Text")))
			: answer.Error!;

		if (answer.Ok && answer.Items.Count == 0)
		{
			text = "It has written nothing.";
		}

		Dialogs.ShowText(this, $"Log — {row.Name}", text,
			"The last 300 lines. Lines marked ! went to stderr.");
	}

	private async Task CheckUpdates()
	{
		if (Model is not { } m)
		{
			return;
		}

		var answer = await m.AskAsync(ContainerVerbs.ImagesCheck);
		if (!answer.Ok)
		{
			m.ActionResult = answer.Error!;
			return;
		}

		m.Rows.Clear();
		foreach (var item in answer.Items)
		{
			m.Rows.Add(new ObjectRow(NodeKind.Images, item));
		}

		var newer = answer.Items.Count(i => Json.Bool(i, "UpdateAvailable") == true);
		var unknown = answer.Items.Count(i => Json.Bool(i, "UpdateAvailable") is null);
		m.ActionResult = $"Asked the registries: {newer} image(s) have a newer image under the same tag"
			+ (unknown > 0 ? $", {unknown} could not be checked (see each one's properties)." : ".");
	}

	private async Task ShowVolumeVersions()
	{
		if (Model is not { SelectedRow: { } row } m)
		{
			return;
		}

		var answer = await m.AskAsync(ContainerVerbs.VolumeVersions, new[] { row.Name });
		if (!answer.Ok || answer.First is not { } volume)
		{
			m.ActionResult = answer.Error ?? "Get-OS7ContainerVolume answered nothing.";
			return;
		}

		Dialogs.ShowVersions(this, volume);
	}

	private async Task NewContainer()
	{
		if (Model is not { } m)
		{
			return;
		}

		if (await CreateDialog.ShowAsync(this, m))
		{
			await m.RefreshAsync();
		}
	}

	/// <summary>
	/// What setting up the engine does is said BEFORE polkit asks, because
	/// polkit's dialog says that something is installed and not what.
	/// </summary>
	private async Task InstallHost()
	{
		if (Model is not { } m)
		{
			return;
		}

		var question =
			"Make this machine a container host?" + Environment.NewLine + Environment.NewLine
			+ "Install-OS7ContainerHost will:" + Environment.NewLine
			+ "  • create rpool/DATA/lib/docker (backed up) and rpool/DATA/lib/containerd (not backed up), outside the boot environment;" + Environment.NewLine
			+ "  • give the engine its own address ranges, refused if they overlap this machine's network or an open SSH session;" + Environment.NewLine
			+ "  • install docker.io, containerd and runc from the Ubuntu archive this release is pinned to." + Environment.NewLine + Environment.NewLine
			+ "It needs the network, and polkit will ask for an administrator's password.";

		if (await Dialogs.ConfirmAsync(this, "Set up the engine", question, "Set up"))
		{
			await m.InstallHostAsync();
		}
	}

	private async Task CleanUp()
	{
		if (Model is not { } m)
		{
			return;
		}

		if (await CleanupDialog.ShowAsync(this, m))
		{
			await m.RefreshAsync();
		}
	}
}
