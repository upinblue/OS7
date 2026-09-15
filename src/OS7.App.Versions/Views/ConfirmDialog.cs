using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace OS7.App.Versions.Views;

/// <summary>
/// The one question this application asks before it changes anything.
/// </summary>
/// <remarks>
/// <para>
/// BUILT IN CODE RATHER THAN IN XAML, and that is not laziness: a hand-written
/// <c>InitializeComponent</c> beside a generated one is BUILD-NOTES #152, which
/// cost a window that died in its constructor while three checks stayed green.
/// A dialog with four controls has nothing to gain from a second XAML file and
/// nothing to lose by having none.
/// </para>
/// <para>
/// It names no colour and sets no font. Everything here is a control the OS/7
/// design system already themes, so this dialog wears the same Windows 2000 face
/// as the window that opened it without check-gui-tokens.py having to make an
/// exception for it (G9).
/// </para>
/// <para>
/// CANCEL IS THE DEFAULT. Enter closes this without restoring, and Escape does
/// the same — the destructive answer is the one that has to be aimed at.
/// </para>
/// </remarks>
public static class ConfirmDialog
{
	public static async Task<bool> AskAsync(Window owner, string title, string question)
	{
		var answered = new TaskCompletionSource<bool>();

		var yes = new Button { Content = "Restore", MinWidth = 90 };
		var no = new Button { Content = "Cancel", MinWidth = 90, IsCancel = true, IsDefault = true };

		var dialog = new Window
		{
			Title = title,
			SizeToContent = SizeToContent.WidthAndHeight,
			WindowStartupLocation = WindowStartupLocation.CenterOwner,
			CanResize = false,
			ShowInTaskbar = false,
			Content = new StackPanel
			{
				Margin = new Thickness(16),
				Spacing = 16,
				Children =
				{
					new TextBlock
					{
						Text = question,
						MaxWidth = 420,
						TextWrapping = TextWrapping.Wrap,
					},
					new StackPanel
					{
						Orientation = Orientation.Horizontal,
						HorizontalAlignment = HorizontalAlignment.Right,
						Spacing = 8,
						Children = { yes, no },
					},
				},
			},
		};

		yes.Click += (_, _) => { answered.TrySetResult(true); dialog.Close(); };
		no.Click += (_, _) => { answered.TrySetResult(false); dialog.Close(); };

		// A dialog closed by the title bar's X is a NO. Without this the task
		// never completes and the caller waits for an answer that is not coming.
		dialog.Closed += (_, _) => answered.TrySetResult(false);

		await dialog.ShowDialog(owner);
		return await answered.Task;
	}
}
