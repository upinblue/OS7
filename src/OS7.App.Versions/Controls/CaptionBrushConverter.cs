using System.Globalization;
using Avalonia;
using Avalonia.Data.Converters;
using Avalonia.Media;

namespace OS7.App.Versions.Controls;

/// <summary>
/// True gives the active caption gradient, false the inactive one.
/// </summary>
/// <remarks>
/// <para>
/// docs/VERSIONS-PLAN.md V12. The selected point in time wears the caption
/// Windows 2000 used for the window you are working in; everything behind it
/// wears the one it used for the windows you are not. That is the entire
/// "now versus then" signal, and it needed no new colour.
/// </para>
/// <para>
/// A CONVERTER RATHER THAN A PROPERTY ON THE VIEW MODEL, on purpose: the view
/// model would then be holding a brush, and G9 says colours live in
/// <c>Tokens.axaml</c> and are reached by key. This looks the key up and holds
/// nothing.
/// </para>
/// </remarks>
public sealed class CaptionBrushConverter : IValueConverter
{
	public static readonly CaptionBrushConverter Instance = new();

	public const string ActiveKey = "os7_caption_active_brush";
	public const string InactiveKey = "os7_caption_inactive_brush";

	public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
	{
		var key = value is true ? ActiveKey : InactiveKey;

		if (Application.Current?.TryGetResource(key, null, out var brush) == true)
		{
			return brush;
		}

		// A missing resource is a design-system defect, not a reason for the
		// window to fall over. Transparent is visibly wrong, which is what a
		// defect should be.
		return Brushes.Transparent;
	}

	public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
		throw new NotSupportedException("A caption does not set which layer is in front.");
}
