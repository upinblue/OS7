using Avalonia;

namespace OS7.App.Versions;

internal static class Program
{
	/// <summary>
	/// <c>os7-versions &lt;absolute path&gt;</c>, and that is the whole contract
	/// between OS/7 and whatever file manager is installed (VERSIONS-PLAN V3).
	/// </summary>
	[STAThread]
	public static int Main(string[] args)
	{
		// Before Avalonia is touched: --self-test has to run where there is no
		// display, which is the build container and eventually the ISO build.
		if (args.Contains("--self-test"))
		{
			return SelfTest.Run();
		}

		return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
	}

	/// <summary>
	/// The path the file manager handed over, or null.
	/// </summary>
	/// <remarks>
	/// The first argument that is not a switch. Nothing is inferred when there
	/// is none — a window opened with no subject would have to guess one, and
	/// the honest answer is to say what it expected.
	/// </remarks>
	public static string? TargetPath(IReadOnlyList<string> args) =>
		args.FirstOrDefault(a => !a.StartsWith('-'));

	public static AppBuilder BuildAvaloniaApp() =>
		AppBuilder.Configure<App>()
			.UsePlatformDetect()
			.LogToTrace();
}
