using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OS7.App.Containers.Model;
using OS7.Ui.Controls;

namespace OS7.App.Containers.Views;

/// <summary>
/// The small windows: a question, a text to read, a volume's versions, and the
/// pieces the two larger dialogs are built from.
/// </summary>
/// <remarks>
/// BUILT IN CODE, as the Versions window's dialog is: a hand-written
/// InitializeComponent beside a generated one is BUILD-NOTES #152, and a dialog
/// with a handful of controls gains nothing from a XAML file. None of them names
/// a colour or a font — every control here is one the OS/7 design system themes,
/// and the brushes come from its tokens by key (G9).
/// </remarks>
public static class Dialogs
{
	/// <summary>A sunken white field around a text box: Windows 2000's edit control.</summary>
	public static Control Field(TextBox box)
	{
		box.Classes.Add("field");
		return new BevelBorder { Child = box, Theme = Theme("os7_sunken_pane") };
	}

	public static Control Sunken(Control child) =>
		new BevelBorder { Child = child, Padding = new Thickness(6), Theme = Theme("os7_sunken_pane") };

	/// <summary>A control theme of the design system, by its key.</summary>
	private static Avalonia.Styling.ControlTheme? Theme(string key) =>
		Application.Current is { } app && app.TryGetResource(key, app.ActualThemeVariant, out var value)
			? value as Avalonia.Styling.ControlTheme
			: null;

	public static TextBlock Muted(string text) =>
		new() { Text = text, TextWrapping = TextWrapping.Wrap, Classes = { "muted" } };

	public static TextBlock Label(string text) =>
		new() { Text = text, Margin = new Thickness(0, 6, 0, 2) };

	public static StackPanel Buttons(params Button[] buttons)
	{
		var panel = new StackPanel
		{
			Orientation = Orientation.Horizontal,
			HorizontalAlignment = HorizontalAlignment.Right,
			Spacing = 8,
			Margin = new Thickness(0, 12, 0, 0),
		};
		foreach (var b in buttons)
		{
			panel.Children.Add(b);
		}

		return panel;
	}

	public static Window Dialog(string title, Control content, double width) => new()
	{
		Title = title,
		Width = width,
		SizeToContent = SizeToContent.Height,
		WindowStartupLocation = WindowStartupLocation.CenterOwner,
		ShowInTaskbar = false,
		Content = new Border { Padding = new Thickness(16), Child = content },
	};

	/// <summary>
	/// The one question asked before anything is removed. CANCEL IS THE DEFAULT:
	/// Enter and Escape both decline, so the destructive answer has to be aimed at.
	/// </summary>
	public static async Task<bool> ConfirmAsync(Window owner, string title, string question, string yesLabel)
	{
		var answered = new TaskCompletionSource<bool>();
		var yes = new Button { Content = yesLabel, MinWidth = 90 };
		var no = new Button { Content = "Cancel", MinWidth = 90, IsCancel = true, IsDefault = true };

		var dialog = Dialog(title, new StackPanel
		{
			Spacing = 4,
			Children =
			{
				new TextBlock { Text = question, MaxWidth = 460, TextWrapping = TextWrapping.Wrap },
				Buttons(yes, no),
			},
		}, 500);

		yes.Click += (_, _) => { answered.TrySetResult(true); dialog.Close(); };
		no.Click += (_, _) => { answered.TrySetResult(false); dialog.Close(); };
		dialog.Closed += (_, _) => answered.TrySetResult(false);

		await dialog.ShowDialog(owner);
		return await answered.Task;
	}

	/// <summary>A text to read — a log — in the fixed-pitch face, and selectable.</summary>
	public static void ShowText(Window owner, string title, string text, string note)
	{
		var box = new TextBox
		{
			Text = text,
			IsReadOnly = true,
			AcceptsReturn = true,
			TextWrapping = TextWrapping.NoWrap,
			Height = 440,
			VerticalContentAlignment = VerticalAlignment.Top,
			Classes = { "mono" },
		};
		ScrollViewer.SetHorizontalScrollBarVisibility(box, Avalonia.Controls.Primitives.ScrollBarVisibility.Auto);
		ScrollViewer.SetVerticalScrollBarVisibility(box, Avalonia.Controls.Primitives.ScrollBarVisibility.Auto);

		var close = new Button { Content = "Close", MinWidth = 90, IsDefault = true, IsCancel = true };
		var window = Dialog(title, new StackPanel
		{
			Spacing = 6,
			Children = { Muted(note), Field(box), Buttons(close) },
		}, 820);
		close.Click += (_, _) => window.Close();
		window.Show(owner);
	}

	/// <summary>
	/// A volume's versions, as Get-OS7ContainerVolume -IncludeVersions read them
	/// as root — and the command that restores a file from one.
	/// </summary>
	/// <remarks>
	/// NOT THE VERSIONS WINDOW, and that is a measured consequence rather than a
	/// choice: a volume's data is under /var/lib/docker, which the engine makes
	/// 0710 root:root, and os7-versions runs as the user by design (VERSIONS-PLAN
	/// V19). So this reads the versions through the same root channel as
	/// everything else here and says how to restore one, instead of opening a
	/// window that could only report a permission it was never going to have.
	/// </remarks>
	public static void ShowVersions(Window owner, JsonElement volume)
	{
		var name = Json.Text(volume, "Name");
		var path = Json.Text(volume, "Mountpoint");
		var list = new StackPanel { Spacing = 2 };
		var versions = Json.Get(volume, "Versions");
		var any = false;

		if (versions is { ValueKind: JsonValueKind.Array } a)
		{
			foreach (var v in a.EnumerateArray())
			{
				any = true;
				var current = Json.Bool(v, "IsCurrent") == true;
				var when = ViewModels.Columns.When(Json.Text(v, current ? "Modified" : "Created"));
				var snapshot = Json.Text(v, "SnapshotName");
				list.Children.Add(new TextBlock
				{
					Text = current ? $"{when}   now" : $"{when}   {snapshot}",
					FontWeight = current ? FontWeight.Bold : FontWeight.Normal,
				});
			}
		}

		if (!any)
		{
			list.Children.Add(Muted(Json.Text(volume, "Reason") is { Length: > 0 } r
				? r
				: "No snapshot holds this volume yet."));
		}

		var command = new TextBox
		{
			Text = $"sudo pwsh -NoProfile -c \"Restore-OS7File -Path '{path}/<file>' -Snapshot '<snapshot>'\"",
			IsReadOnly = true,
			Classes = { "mono" },
		};

		var close = new Button { Content = "Close", MinWidth = 90, IsDefault = true, IsCancel = true };
		var window = Dialog($"Previous versions — {name}", new StackPanel
		{
			Spacing = 6,
			Children =
			{
				Muted($"Backed up: {(Json.Bool(volume, "BackedUp") == true ? "yes" : "no")}, on {Json.Text(volume, "Dataset")}. "
					+ $"{Json.Text(volume, "Snapshots")} snapshot(s) of that dataset exist."),
				Sunken(new ScrollViewer { MaxHeight = 300, Content = list }),
				Muted("A volume's data is root's. To put one file back from one of these versions, in a terminal:"),
				Field(command),
				Buttons(close),
			},
		}, 640);
		close.Click += (_, _) => window.Close();
		window.Show(owner);
	}
}
