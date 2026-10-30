using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OS7.App.Containers.Model;
using OS7.App.Containers.Services;
using OS7.App.Containers.ViewModels;

namespace OS7.App.Containers.Views;

/// <summary>
/// Clean up: what is unused, what removing it would free — and only then the
/// removal, of exactly what was ticked.
/// </summary>
/// <remarks>
/// <para>
/// THE TICKS START WHERE THE CMDLET SAYS. <c>Get-OS7ContainerUnused</c> marks
/// each item Recommended or not — a dangling image yes, a stopped container no,
/// because removing it deletes its configuration — and this dialog pre-selects
/// by that and decides nothing of its own. Named volumes are not even listed
/// unless the operator asks, because a named volume is somebody's data on
/// purpose.
/// </para>
/// <para>
/// WHAT WAS SHOWN IS WHAT IS SENT. The ticked items go to
/// <c>Remove-OS7ContainerUnused</c> by Id, which checks each one is STILL
/// unused and reports per item — so a container started between the preview
/// and the click is left alone and says so.
/// </para>
/// </remarks>
public static class CleanupDialog
{
	private sealed record Item(JsonElement Value, CheckBox Box);

	public static async Task<bool> ShowAsync(Window owner, MainWindowViewModel model)
	{
		var removed = false;
		var items = new List<Item>();
		var list = new StackPanel { Spacing = 2 };
		var total = new TextBlock { FontWeight = FontWeight.Bold };
		var named = new CheckBox { Content = "Also list NAMED volumes nothing uses (never pre-selected)" };
		var results = new StackPanel { Spacing = 2 };

		var remove = new Button { Content = "Remove selected…", MinWidth = 120, IsEnabled = false };
		var close = new Button { Content = "Close", MinWidth = 90, IsCancel = true, IsDefault = true };

		var window = Dialogs.Dialog("Clean up", new StackPanel
		{
			Spacing = 6,
			Children =
			{
				Dialogs.Muted("Nothing has been removed. Each item says why it counts as unused; what is pre-selected is what OS/7 considers safe."),
				named,
				Dialogs.Sunken(new ScrollViewer { Height = 340, Content = list }),
				total,
				results,
				Dialogs.Buttons(remove, close),
			},
		}, 860);

		void Recount()
		{
			var chosen = items.Where(i => i.Box.IsChecked == true).ToArray();
			var bytes = chosen.Sum(i => Json.Long(i.Value, "Size") is > 0 and var b ? b : 0);
			total.Text = $"{chosen.Length} selected — about {Json.Size(bytes)} freed";
			remove.IsEnabled = chosen.Length > 0 && !model.Busy;
		}

		async Task Load()
		{
			items.Clear();
			list.Children.Clear();
			var answer = await model.AskAsync(ContainerVerbs.Unused, named.IsChecked == true ? new[] { "named" } : null);
			if (!answer.Ok)
			{
				list.Children.Add(new SelectableTextBlock { Text = answer.Error, TextWrapping = TextWrapping.Wrap });
				Recount();
				return;
			}

			if (answer.Items.Count == 0)
			{
				list.Children.Add(Dialogs.Muted("Nothing on this machine is unused."));
			}

			foreach (var value in answer.Items)
			{
				var box = new CheckBox { IsChecked = Json.Bool(value, "Recommended") == true, VerticalAlignment = VerticalAlignment.Top };
				box.IsCheckedChanged += (_, _) => Recount();
				var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,90,*,90"), Margin = new Thickness(0, 2) };
				row.Children.Add(box);
				Add(row, 1, new TextBlock { Text = Json.Text(value, "Kind") });
				Add(row, 2, new StackPanel
				{
					Children =
					{
						new TextBlock { Text = Json.Text(value, "Name"), TextTrimming = TextTrimming.CharacterEllipsis },
						new TextBlock { Text = Json.Text(value, "Reason"), TextWrapping = TextWrapping.Wrap, Classes = { "muted" } },
					},
				});
				Add(row, 3, new TextBlock { Text = Json.Size(Json.Long(value, "Size")), HorizontalAlignment = HorizontalAlignment.Right });
				list.Children.Add(row);
				items.Add(new Item(value, box));
			}

			Recount();
		}

		named.IsCheckedChanged += async (_, _) => await Load();

		remove.Click += async (_, _) =>
		{
			var chosen = items.Where(i => i.Box.IsChecked == true).Select(i => i.Value).ToArray();
			if (chosen.Length == 0 || !await Dialogs.ConfirmAsync(window, "Clean up",
					$"Remove these {chosen.Length} item(s)? Each is checked once more first, and one that is in use by then is left alone.",
					"Remove"))
			{
				return;
			}

			var json = JsonSerializer.Serialize(chosen);
			var answer = await model.RunAsync("Clean up", ContainerVerbs.Cleanup, null, json);
			results.Children.Clear();
			if (!answer.Ok)
			{
				results.Children.Add(new SelectableTextBlock { Text = answer.Error, TextWrapping = TextWrapping.Wrap });
				return;
			}

			removed = true;
			foreach (var r in answer.Items)
			{
				var reason = Json.Text(r, "Reason");
				results.Children.Add(new TextBlock
				{
					Text = $"{Json.Text(r, "Kind")} {Json.Text(r, "Name")}: {Json.Text(r, "Outcome")}" + (reason.Length > 0 ? $" — {reason}" : string.Empty),
					TextWrapping = TextWrapping.Wrap,
				});
			}

			await Load();
		};

		close.Click += (_, _) => window.Close();
		window.Opened += async (_, _) => await Load();
		await window.ShowDialog(owner);
		return removed;
	}

	private static void Add(Grid grid, int column, Control child)
	{
		Grid.SetColumn(child, column);
		grid.Children.Add(child);
	}
}
