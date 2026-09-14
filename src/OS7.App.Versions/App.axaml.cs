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
	/// state the operator sees rather than a frame they miss — the ZFS query
	/// alone costs about 570 ms (VERSIONS-PLAN §2).
	/// </summary>
	private static async Task LoadAsync(MainWindowViewModel model, string path)
	{
		var result = await new VersionLoader().LoadAsync(path).ConfigureAwait(true);

		// One format for the whole list, chosen once it is known what is in it.
		VersionEntry.AssignCaptions(result.Entries);

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

		model.Message = result.Target.Explanation;
		model.Phase = result.Entries.Count > 0
			? VersionsPhase.Listing
			: VersionsPhase.NoHistory;
	}
}
