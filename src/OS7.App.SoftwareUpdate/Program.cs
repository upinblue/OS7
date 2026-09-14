using Avalonia;

namespace OS7.App.SoftwareUpdate;

internal static class Program
{
	/// <summary>
	/// The entry point.
	/// </summary>
	/// <remarks>
	/// <c>--self-test</c> is checked BEFORE Avalonia is touched, on purpose. It
	/// has to run where there is no display — in the build container, and
	/// eventually in the ISO build the way <c>os7-setup --self-test</c> does
	/// (hook 0080), so that a decision that has stopped being true fails a
	/// build rather than a machine. Constructing an AppBuilder first would make
	/// the check depend on the thing it is meant to run without.
	/// </remarks>
	[STAThread]
	public static int Main(string[] args)
	{
		if (args.Contains("--self-test"))
		{
			return SelfTest.Run();
		}

		return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
	}

	// Named exactly this because Avalonia's XAML tooling looks for it.
	public static AppBuilder BuildAvaloniaApp() =>
		AppBuilder.Configure<App>()
			.UsePlatformDetect()
			.LogToTrace();
}
