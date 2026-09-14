using Avalonia;
using Avalonia.Controls;

namespace OS7.App.Versions.Controls;

/// <summary>
/// Overlapping layers stepping up and to the left, the last child in front.
/// </summary>
/// <remarks>
/// <para>
/// docs/VERSIONS-PLAN.md V11. Apple's Time Machine recedes into perspective;
/// Windows 2000 had no compositing and no 3-D, but it had a well-known way of
/// showing the same kind of thing several times over — <c>Window → Cascade</c>
/// in every MDI application. This is that, used to mean "the same folder, at
/// several times".
/// </para>
/// <para>
/// CHILDREN ARE OLDEST FIRST. The last child is the selected point in time and
/// is drawn in front, because Avalonia paints a panel's children in order.
/// Ordering the collection is therefore the whole of the Z-order, with no
/// <c>ZIndex</c> to keep in step with it.
/// </para>
/// <para>
/// Every layer is the same SIZE. Scaling them would be perspective by another
/// name, and a bevel that is not one pixel is not a Windows 2000 bevel — the
/// look this design system is built on survives translation and does not
/// survive scaling.
/// </para>
/// </remarks>
public class CascadePanel : Panel
{
	/// <summary>How far each layer behind steps left.</summary>
	public static readonly StyledProperty<double> StepXProperty =
		AvaloniaProperty.Register<CascadePanel, double>(nameof(StepX), 14);

	/// <summary>How far each layer behind steps up.</summary>
	public static readonly StyledProperty<double> StepYProperty =
		AvaloniaProperty.Register<CascadePanel, double>(nameof(StepY), 10);

	static CascadePanel()
	{
		AffectsMeasure<CascadePanel>(StepXProperty, StepYProperty);
		AffectsArrange<CascadePanel>(StepXProperty, StepYProperty);
	}

	public double StepX
	{
		get => GetValue(StepXProperty);
		set => SetValue(StepXProperty, value);
	}

	public double StepY
	{
		get => GetValue(StepYProperty);
		set => SetValue(StepYProperty, value);
	}

	/// <summary>
	/// How many layers of room to keep, however many there actually are.
	/// </summary>
	/// <remarks>
	/// MEASURED ON A MACHINE: stepping to the oldest version left one layer
	/// behind instead of four, so the front panel grew and moved as the
	/// operator walked the timeline — the panel they are reading changing size
	/// under them at every step. Reserving the room keeps the front layer at
	/// one place and one size, and lets the stack behind it get shorter, which
	/// is the thing that is actually running out.
	/// </remarks>
	public static readonly StyledProperty<int> ReservedLayersProperty =
		AvaloniaProperty.Register<CascadePanel, int>(nameof(ReservedLayers), 1);

	public int ReservedLayers
	{
		get => GetValue(ReservedLayersProperty);
		set => SetValue(ReservedLayersProperty, value);
	}

	/// <summary>Steps of room to leave: the reserved count, or more if there are more.</summary>
	private int Reserved => Math.Max(1, Math.Max(ReservedLayers, Children.Count));

	protected override Size MeasureOverride(Size availableSize)
	{
		var behind = Math.Max(0, Reserved - 1);
		var layer = new Size(
			Math.Max(0, availableSize.Width - (behind * StepX)),
			Math.Max(0, availableSize.Height - (behind * StepY)));

		foreach (var child in Children)
		{
			child.Measure(layer);
		}

		// The whole stack is one layer plus what the steps add back.
		return availableSize;
	}

	protected override Size ArrangeOverride(Size finalSize)
	{
		var count = Children.Count;
		if (count == 0)
		{
			return finalSize;
		}

		var reserved = Reserved;
		var behind = reserved - 1;
		var width = Math.Max(0, finalSize.Width - (behind * StepX));
		var height = Math.Max(0, finalSize.Height - (behind * StepY));

		for (var i = 0; i < count; i++)
		{
			// Child 0 is the OLDEST and sits furthest back; the last child is
			// the selected time and sits in front — the direction a cascade of
			// windows steps.
			//
			// Positions are counted FROM THE FRONT, not from the back, so the
			// front layer stays put when the stack behind it runs short.
			var step = reserved - count + i;
			Children[i].Arrange(new Rect(step * StepX, step * StepY, width, height));
		}

		return finalSize;
	}
}
