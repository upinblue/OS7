using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using OS7.App.Versions.Services;
using OS7.App.Versions.ViewModels;
using OS7.App.Versions.Views;

namespace OS7.App.Versions;

public partial class App : Application
{
	public override void Initialize() => AvaloniaXamlLoader.Load(this);

	public override void OnFrameworkInitializationCompleted()
	{
		if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
		{
			var path = Program.TargetPath(desktop.Args ?? Array.Empty<string>());

			var model = new MainWindowViewModel(path ?? string.Empty, Array.Empty<VersionEntry>())
			{
				Phase = path is null ? VersionsPhase.Failed : VersionsPhase.Loading,
			};

			if (path is null)
			{
				// V3: the file manager hands over a path, and there is nothing
				// sensible to show without one. Saying what was expected beats
				// guessing at the home directory.
				model.Message =
					"os7-versions expects the path of a file or folder: "
					+ "os7-versions /home/you/notes.txt";
			}

			desktop.MainWindow = new MainWindow { DataContext = model };

			if (path is not null)
			{
				_ = LoadAsync(model, path);
			}
		}

		base.OnFrameworkInitializationCompleted();
	}

	/// <summary>
	/// Fill the window once it exists, so "Looking for previous versions…" is a
	/// state the operator sees rather than a frame they miss.
	/// </summary>
	/// <remarks>
	/// EVERY FAILURE IS THE CMDLET'S SENTENCE. `Get-OS7FileVersion` refuses a
	/// path that is not on ZFS, a path that IS a mountpoint, and a dataset that
	/// is not mounted, each with its own wording and its own instruction. They
	/// arrive here as the message and go on the screen unaltered.
	/// </remarks>
	private static async Task LoadAsync(MainWindowViewModel model, string path)
	{
		var result = await new VersionLoader().LoadAsync(path).ConfigureAwait(true);

		foreach (var entry in result.Entries)
		{
			model.Entries.Add(entry);
		}

		if (result.Error is not null)
		{
			model.Message = result.Error;
			model.Phase = VersionsPhase.Failed;
			return;
		}

		if (result.Entries.Count == 0)
		{
			// The cmdlet answered and had nothing. It throws for the cases it
			// can explain, so this is the remaining one: a path nothing holds.
			model.Message =
				$"No snapshot of this machine holds {path}, and there is nothing there now.";
			model.Phase = VersionsPhase.NoHistory;
			return;
		}

		model.Phase = VersionsPhase.Listing;
	}
}
