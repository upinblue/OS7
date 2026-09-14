using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace OS7.Ui.Controls;

/// <summary>
/// The classic two-pixel bevel, and the whole visual grammar of this design
/// system in one control.
/// </summary>
/// <remarks>
/// <para>
/// The theme package's <c>gtk.css</c> calls it "the classic 2px bevel" and
/// describes it exactly: an outer edge with one colour top-left and another
/// bottom-right, and an inner edge with a third and a fourth. Raised, pressed
/// and sunken are the same four positions with different colours in them:
/// </para>
/// <list type="table">
///   <item><term>Raised</term><description>outer hilight / dkshadow, inner light / shadow</description></item>
///   <item><term>Pressed</term><description>outer dkshadow / hilight, inner shadow / light</description></item>
///   <item><term>Sunken</term><description>outer shadow / hilight, inner dkshadow / light</description></item>
/// </list>
/// <para>
/// WHICH COLOUR GOES WHERE IS NOT DECIDED HERE. The four edges are properties,
/// and the control themes in <c>Theme/Controls.axaml</c> fill them from the
/// tokens. That is not indirection for its own sake: G9 says no colour literal
/// lives outside <c>Theme/Tokens.axaml</c>, and a control that named its own
/// greys would be the first exception to it. It also makes
/// <c>check-gui-tokens.py</c>'s job a grep rather than a parse.
/// </para>
/// <para>
/// Edges are drawn with <see cref="DrawingContext.FillRectangle(IBrush, Rect)"/>
/// rather than with pens. A one-pixel pen straddles the coordinate it is given,
/// so it lands on a half-pixel and is antialiased into two grey rows - which is
/// exactly the thing this look cannot survive. A filled rectangle covers whole
/// device pixels.
/// </para>
/// </remarks>
public class BevelBorder : Decorator
{
	/// <summary>The face behind the child. Null draws nothing.</summary>
	public static readonly StyledProperty<IBrush?> BackgroundProperty =
		AvaloniaProperty.Register<BevelBorder, IBrush?>(nameof(Background));

	public static readonly StyledProperty<IBrush?> OuterTopLeftProperty =
		AvaloniaProperty.Register<BevelBorder, IBrush?>(nameof(OuterTopLeft));

	public static readonly StyledProperty<IBrush?> OuterBottomRightProperty =
		AvaloniaProperty.Register<BevelBorder, IBrush?>(nameof(OuterBottomRight));

	public static readonly StyledProperty<IBrush?> InnerTopLeftProperty =
		AvaloniaProperty.Register<BevelBorder, IBrush?>(nameof(InnerTopLeft));

	public static readonly StyledProperty<IBrush?> InnerBottomRightProperty =
		AvaloniaProperty.Register<BevelBorder, IBrush?>(nameof(InnerBottomRight));

	static BevelBorder()
	{
		AffectsRender<BevelBorder>(
			BackgroundProperty,
			OuterTopLeftProperty, OuterBottomRightProperty,
			InnerTopLeftProperty, InnerBottomRightProperty);

		// Padding is NOT registered here. Decorator already declares
		// AffectsMeasure for it; doing so again would attach a second handler
		// to the same property and invalidate twice for one change.
	}

	public IBrush? Background
	{
		get => GetValue(BackgroundProperty);
		set => SetValue(BackgroundProperty, value);
	}

	public IBrush? OuterTopLeft
	{
		get => GetValue(OuterTopLeftProperty);
		set => SetValue(OuterTopLeftProperty, value);
	}

	public IBrush? OuterBottomRight
	{
		get => GetValue(OuterBottomRightProperty);
		set => SetValue(OuterBottomRightProperty, value);
	}

	public IBrush? InnerTopLeft
	{
		get => GetValue(InnerTopLeftProperty);
		set => SetValue(InnerTopLeftProperty, value);
	}

	public IBrush? InnerBottomRight
	{
		get => GetValue(InnerBottomRightProperty);
		set => SetValue(InnerBottomRightProperty, value);
	}

	/// <summary>The bevel itself, which is always two pixels on every side.</summary>
	private static readonly Thickness BevelThickness = new(2);

	protected override Size MeasureOverride(Size availableSize)
	{
		var inset = Padding + BevelThickness;
		var child = Child;

		if (child is null)
		{
			return new Size(inset.Left + inset.Right, inset.Top + inset.Bottom);
		}

		child.Measure(availableSize.Deflate(inset));
		return child.DesiredSize.Inflate(inset);
	}

	protected override Size ArrangeOverride(Size finalSize)
	{
		var inset = Padding + BevelThickness;
		Child?.Arrange(new Rect(finalSize).Deflate(inset));
		return finalSize;
	}

	public override void Render(DrawingContext context)
	{
		var width = Bounds.Width;
		var height = Bounds.Height;

		if (width <= 0 || height <= 0)
		{
			return;
		}

		if (Background is { } face)
		{
			context.FillRectangle(face, new Rect(0, 0, width, height));
		}

		DrawEdges(context, OuterTopLeft, OuterBottomRight, 0, 0, width, height);
		DrawEdges(context, InnerTopLeft, InnerBottomRight, 1, 1, width - 2, height - 2);
	}

	/// <summary>
	/// One ring of the bevel: an L along the top and left in one brush, an L
	/// along the bottom and right in the other. The corners belong to the
	/// top-left brush, which is how Windows drew them.
	/// </summary>
	private static void DrawEdges(
		DrawingContext context,
		IBrush? topLeft,
		IBrush? bottomRight,
		double x,
		double y,
		double width,
		double height)
	{
		if (width <= 0 || height <= 0)
		{
			return;
		}

		if (bottomRight is { } br)
		{
			context.FillRectangle(br, new Rect(x, y + height - 1, width, 1));
			context.FillRectangle(br, new Rect(x + width - 1, y, 1, height));
		}

		if (topLeft is { } tl)
		{
			context.FillRectangle(tl, new Rect(x, y, width, 1));
			context.FillRectangle(tl, new Rect(x, y, 1, height));
		}
	}
}
