using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using OS7.App.Versions.Services;
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
		RestoreButton.Click += OnRestore;
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

		if (version is null || !version.Exists || version.IsFolder)
		{
			return;
		}

		// SnapshotPath, not Path: Path is the LIVE file this is a version of,
		// and opening that would show today's contents under yesterday's
		// caption. The bytes are the ones under .zfs/snapshot.
		await Launcher.LaunchFileInfoAsync(new FileInfo(version.SnapshotPath));
	}

	/// <summary>
	/// Put this version back over the live file — the only verb here that changes
	/// anything.
	/// </summary>
	/// <remarks>
	/// <para>
	/// VERSIONS-PLAN V7 and V9. It asks first, in a dialog naming the file and
	/// the moment, and then hands the whole job to <c>Restore-OS7File</c>: this
	/// method copies nothing, renames nothing and snapshots nothing. What is kept
	/// before the overwrite — a ZFS snapshot with privilege, the file renamed
	/// aside without it (V8/V19) — is the cmdlet's decision, and an administrator
	/// typing the same verb over ssh gets exactly this.
	/// </para>
	/// <para>
	/// THE LIST IS RELOADED AFTERWARDS, and it is not cosmetic. A restore creates
	/// a new version — the state it replaced — and it is the row somebody comes
	/// back for within the minute, when they realise they restored the wrong one.
	/// Leaving the window showing the history from before the change would hide
	/// the one entry that undoes it.
	/// </para>
	/// </remarks>
	private async void OnRestore(object? sender, RoutedEventArgs e)
	{
		var model = Model;
		var version = model?.Selected?.Version;

		if (model is null || version is null || !model.CanRestore ||
			version.SnapshotName is null)
		{
			return;
		}

		if (!await ConfirmDialog.AskAsync(this, "Restore a previous version",
				model.RestorePrompt))
		{
			return;
		}

		RestoreButton.IsEnabled = false;
		try
		{
			var failure = await new VersionLoader()
				.RestoreAsync(version.Path, version.SnapshotName);

			if (failure is not null)
			{
				// The machine's own words, unaltered (V6). Restore-OS7File
				// refuses in complete sentences that name the way forward, and
				// paraphrasing one into "restore failed" deletes the instruction.
				model.Message = failure;
				model.Phase = VersionsPhase.Failed;
				return;
			}

			await App.ReloadAsync(model);
		}
		finally
		{
			RestoreButton.IsEnabled = true;
		}
	}

	/// <summary>
	/// Write a copy somewhere the operator chooses. The live file is untouched.
	/// </summary>
	private async void OnCopy(object? sender, RoutedEventArgs e)
	{
		var model = Model;
		var version = model?.Selected?.Version;

		if (model is null || version is null || !version.Exists || version.IsFolder)
		{
			return;
		}

		// The name carries the moment it came from, because a folder with
		// notes.txt and notes.txt beside it helps nobody.
		var stamp = version.Created.ToLocalTime().ToString("yyyy-MM-dd-HHmm");
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
			File.Copy(version.SnapshotPath, destination, overwrite: true);
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
