using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using OS7.App.Versions.Model;
using OS7.App.Versions.ViewModels;

namespace OS7.App.Versions.Views;

public partial class MainWindow : Window
{
	public MainWindow()
	{
		// InitializeComponent() IS GENERATED. Writing one here compiles, loads
		// the XAML, and leaves every x:Name'd field null — BUILD-NOTES #152,
		// found on a machine after three green checks.
		InitializeComponent();

		BackButton.Click += (_, _) => Model?.GoBack();
		ForwardButton.Click += (_, _) => Model?.GoForward();
		OpenButton.Click += OnOpen;
		CopyButton.Click += OnCopy;
	}

	private MainWindowViewModel? Model => DataContext as MainWindowViewModel;

	/// <summary>
	/// Open the old version read-only, in whatever handles that kind of file.
	/// </summary>
	/// <remarks>
	/// <para>
	/// VERSIONS-PLAN V7: looking comes before replacing, and this is the verb
	/// that cannot hurt — a file inside <c>.zfs/snapshot</c> is read-only to
	/// everybody, including root, because ZFS will not let a snapshot be
	/// written to.
	/// </para>
	/// <para>
	/// Avalonia's launcher rather than a process: the application starts no
	/// programs of its own, which is the rule check-gui-logic.py holds.
	/// </para>
	/// </remarks>
	private async void OnOpen(object? sender, RoutedEventArgs e)
	{
		var version = Model?.Selected?.Version;

		if (version is null || version.State != VersionState.Present)
		{
			return;
		}

		await Launcher.LaunchFileInfoAsync(new FileInfo(version.Path));
	}

	/// <summary>
	/// Write a copy somewhere the operator chooses. The live file is untouched.
	/// </summary>
	private async void OnCopy(object? sender, RoutedEventArgs e)
	{
		var model = Model;
		var version = model?.Selected?.Version;

		if (model is null || version is null || version.State != VersionState.Present)
		{
			return;
		}

		// The name carries the moment it came from, because a folder with
		// notes.txt and notes.txt beside it helps nobody.
		var stamp = version.Snapshot.Creation.ToLocalTime().ToString("yyyy-MM-dd-HHmm");
		var name = Path.GetFileNameWithoutExtension(model.FileName);
		var extension = Path.GetExtension(model.FileName);

		var picked = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
		{
			Title = "Copy this version to…",
			SuggestedFileName = $"{name}-{stamp}{extension}",
		});

		if (picked?.TryGetLocalPath() is not { } destination)
		{
			return;
		}

		try
		{
			File.Copy(version.Path, destination, overwrite: true);
		}
		catch (Exception ex)
		{
			// The machine's own words. A copy that failed because the target is
			// full or read-only is a sentence an operator can act on.
			model.Message = ex.Message;
			model.Phase = VersionsPhase.Failed;
		}
	}
}
