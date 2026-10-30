using Avalonia;

namespace OS7.App.Containers;

internal static class Program
{
	[STAThread]
	public static int Main(string[] args)
	{
		// Before Avalonia is touched: --self-test runs where there is no display,
		// which is the build container and the package build.
		if (args.Contains("--self-test"))
		{
			return SelfTest.Run();
		}

		return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
	}

	public static AppBuilder BuildAvaloniaApp() =>
		AppBuilder.Configure<App>()
			.UsePlatformDetect()
			.LogToTrace();
}
