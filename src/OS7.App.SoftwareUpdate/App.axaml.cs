using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using OS7.App.SoftwareUpdate.Services;
using OS7.App.SoftwareUpdate.ViewModels;
using OS7.App.SoftwareUpdate.Views;

namespace OS7.App.SoftwareUpdate;

public partial class App : Application
{
	public override void Initialize() => AvaloniaXamlLoader.Load(this);

	public override void OnFrameworkInitializationCompleted()
	{
		if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
		{
			var model = new MainWindowViewModel(new Os7Cli());

			desktop.MainWindow = new MainWindow { DataContext = model };

			// Ask the machine once the window exists, so that "Checking for new
			// software…" is a state the operator SEES rather than a frame they
			// miss. Get-OS7Release verifies an index signature and every
			// descriptor's hash before it lists anything, so it is not instant
			// and must not pretend to be.
			_ = model.RefreshAsync();
		}

		base.OnFrameworkInitializationCompleted();
	}
}
