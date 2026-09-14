using Avalonia.Controls;
using Avalonia.Interactivity;
using OS7.App.SoftwareUpdate.ViewModels;

namespace OS7.App.SoftwareUpdate.Views;

public partial class MainWindow : Window
{
	public MainWindow()
	{
		// InitializeComponent() IS GENERATED, AND MUST NOT BE WRITTEN BY HAND.
		//
		// This class had its own `private void InitializeComponent() =>
		// AvaloniaXamlLoader.Load(this);`, which compiled cleanly, shadowed the
		// generated one, and loaded the XAML — but the generated one ALSO
		// assigns every x:Name'd control to its field, and the hand-written one
		// does not. So CloseButton and InstallButton stayed null, the
		// constructor threw NullReferenceException, and the application died
		// before a window existed. It reported nothing an operator could see:
		// the menu entry was clicked, the menu closed, and the desktop stayed
		// empty. Found on a machine, because zero checks could see it and the
		// build was green (BUILD-NOTES #152).
		InitializeComponent();

		CloseButton.Click += OnNotNow;
		InstallButton.Click += OnInstall;
	}

	private void OnNotNow(object? sender, RoutedEventArgs e)
	{
		// "Not Now" closes the window and nothing else. It does not remember
		// the answer, does not snooze anything and does not write a preference:
		// whether this machine checks for updates on a schedule is the
		// unattended timer's business (RELEASE-AND-UPDATE-PLAN §6), and a
		// window quietly disabling it would be a fleet-wide policy change made
		// by one click in one session.
		Close();
	}

	private async void OnInstall(object? sender, RoutedEventArgs e)
	{
		if (DataContext is not MainWindowViewModel model)
		{
			return;
		}

		// The polkit prompt happens inside this call, in polkit's own dialog.
		// Nothing here imitates it, and nothing here asks for a password.
		await model.InstallSelectedAsync();
	}
}
