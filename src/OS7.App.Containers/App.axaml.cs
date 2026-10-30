using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using OS7.App.Containers.ViewModels;
using OS7.App.Containers.Views;

namespace OS7.App.Containers;

public partial class App : Application
{
	public override void Initialize() => AvaloniaXamlLoader.Load(this);

	public override void OnFrameworkInitializationCompleted()
	{
		if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
		{
			var model = new MainWindowViewModel();
			desktop.MainWindow = new MainWindow { DataContext = model };

			// The window first, then the question: "Asking the engine…" is a
			// state the operator sees rather than a frame they miss.
			_ = model.StartAsync();
		}

		base.OnFrameworkInitializationCompleted();
	}
}
