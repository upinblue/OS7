using Avalonia.Data.Converters;
using Avalonia.Media;

namespace OS7.App.Containers.ViewModels;

/// <summary>The window's two presentation conversions. Neither decides anything.</summary>
public static class Converters
{
	/// <summary>
	/// A row that needs attention is drawn bold — the cmdlet's NeedsAttention,
	/// shown without a colour of its own, because the palette has no "warning
	/// red" and G9 forbids one here.
	/// </summary>
	public static readonly IValueConverter BoldWhen =
		new FuncValueConverter<bool, FontWeight>(b => b ? FontWeight.Bold : FontWeight.Normal);
}
