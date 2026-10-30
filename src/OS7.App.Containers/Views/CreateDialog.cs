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
/// New container: image, name, ports, volumes, environment — and the cmdlet's
/// answer to "what would this do" BEFORE anything is created.
/// </summary>
/// <remarks>
/// <para>
/// Asked for by the owner for v1 on 2026-10-30, against CT12's "no
/// create-a-container wizard in v1". What made it acceptable is that it is
/// still a front-end: Check runs <c>New-OS7Container -ValidateOnly</c>, and the
/// right-hand pane is that object — the refusals in the cmdlet's words, who can
/// reach each port in CT8's words, whether the image will be pulled. Create is
/// enabled only once the cmdlet has said the description would go ahead, and
/// Create runs the same cmdlet without the switch.
/// </para>
/// <para>
/// Editing anything after Check disables Create again: what was checked is what
/// may be created, and nothing else.
/// </para>
/// </remarks>
public static class CreateDialog
{
	public static async Task<bool> ShowAsync(Window owner, MainWindowViewModel model)
	{
		var created = false;
		var name = new TextBox { PlaceholderText = "web" };
		var image = new TextBox { PlaceholderText = "nginx:1.27" };
		var ports = new TextBox { AcceptsReturn = true, Height = 64, PlaceholderText = "8080:80" };
		var local = new CheckBox { Content = "Ports without an address: this machine only (127.0.0.1)", IsChecked = true };
		var volumes = new TextBox { AcceptsReturn = true, Height = 64, PlaceholderText = "web-data:/usr/share/nginx/html" };
		var environment = new TextBox { AcceptsReturn = true, Height = 64, PlaceholderText = "NAME=value" };
		var restart = new CheckBox { Content = "Start again with the machine (unless-stopped)", IsChecked = true };
		var start = new CheckBox { Content = "Start it once it is created", IsChecked = true };

		var plan = new StackPanel { Spacing = 4 };
		plan.Children.Add(Dialogs.Muted("Check asks New-OS7Container what it would do. Nothing is created until Create."));

		var check = new Button { Content = "Check", MinWidth = 90, IsDefault = true };
		var create = new Button { Content = "Create", MinWidth = 90, IsEnabled = false };
		var cancel = new Button { Content = "Cancel", MinWidth = 90, IsCancel = true };

		var form = new StackPanel
		{
			Spacing = 0,
			Children =
			{
				Dialogs.Label("Image"), Dialogs.Field(image),
				Dialogs.Label("Name"), Dialogs.Field(name),
				Dialogs.Label("Ports — host:container, one per line"), Dialogs.Field(ports), local,
				Dialogs.Label("Volumes — name:/path/in/container, one per line"), Dialogs.Field(volumes),
				Dialogs.Label("Environment — NAME=value, one per line. Values are never shown again."), Dialogs.Field(environment),
				new StackPanel { Margin = new Thickness(0, 8, 0, 0), Spacing = 4, Children = { restart, start } },
			},
		};

		var layout = new Grid { ColumnDefinitions = new ColumnDefinitions("*,16,*") };
		layout.Children.Add(form);
		var right = new DockPanel();
		var heading = new TextBlock { Text = "What it would do", Classes = { "heading" }, Margin = new Thickness(0, 6, 0, 6) };
		DockPanel.SetDock(heading, Dock.Top);
		right.Children.Add(heading);
		right.Children.Add(Dialogs.Sunken(new ScrollViewer { Content = plan }));
		Grid.SetColumn(right, 2);
		layout.Children.Add(right);

		var window = Dialogs.Dialog("New container", new StackPanel
		{
			Children = { layout, Dialogs.Buttons(check, create, cancel) },
		}, 900);

		string? checkedJson = null;

		string Describe(out IReadOnlyList<string> problems)
		{
			var env = CreateForm.Environment(environment.Text);
			problems = env.Problems;
			return CreateForm.ToJson(
				name.Text ?? string.Empty,
				image.Text ?? string.Empty,
				CreateForm.Ports(ports.Text, local.IsChecked == true),
				CreateForm.Lines(volumes.Text),
				env.Values,
				restart.IsChecked == true,
				start.IsChecked == true);
		}

		void Invalidate()
		{
			checkedJson = null;
			create.IsEnabled = false;
		}

		foreach (var box in new[] { name, image, ports, volumes, environment })
		{
			box.TextChanged += (_, _) => Invalidate();
		}

		foreach (var box in new[] { local, restart, start })
		{
			box.IsCheckedChanged += (_, _) => Invalidate();
		}

		check.Click += async (_, _) =>
		{
			var json = Describe(out var inputProblems);
			plan.Children.Clear();
			if (inputProblems.Count > 0)
			{
				foreach (var p in inputProblems)
				{
					plan.Children.Add(new TextBlock { Text = p, TextWrapping = TextWrapping.Wrap });
				}

				return;
			}

			check.IsEnabled = false;
			var answer = await model.AskAsync(ContainerVerbs.Validate, null, json);
			check.IsEnabled = true;
			if (!answer.Ok || answer.First is not { } p0)
			{
				plan.Children.Add(new SelectableTextBlock { Text = answer.Error ?? "New-OS7Container answered nothing.", TextWrapping = TextWrapping.Wrap });
				return;
			}

			ShowPlan(plan, p0);
			if (Json.Bool(p0, "Validated") == true)
			{
				checkedJson = json;
				create.IsEnabled = true;
			}
		};

		create.Click += async (_, _) =>
		{
			if (checkedJson is null)
			{
				return;
			}

			create.IsEnabled = false;
			check.IsEnabled = false;
			plan.Children.Clear();
			plan.Children.Add(Dialogs.Muted("Creating — pulling the image first if this machine does not have it…"));
			var answer = await model.RunAsync("Create", ContainerVerbs.Create, null, checkedJson);
			plan.Children.Clear();
			plan.Children.Add(new SelectableTextBlock { Text = model.ActionResult, TextWrapping = TextWrapping.Wrap });
			check.IsEnabled = true;
			if (answer.Ok)
			{
				created = true;
				cancel.Content = "Close";
			}
		};

		cancel.Click += (_, _) => window.Close();
		await window.ShowDialog(owner);
		return created;
	}

	/// <summary>The cmdlet's plan, line by line, in its own words.</summary>
	private static void ShowPlan(StackPanel plan, JsonElement p)
	{
		var problems = Json.Strings(p, "Problems");
		if (problems.Count > 0)
		{
			plan.Children.Add(new TextBlock { Text = "It would not be created:", FontWeight = FontWeight.Bold });
			foreach (var problem in problems)
			{
				plan.Children.Add(new SelectableTextBlock { Text = "• " + problem, TextWrapping = TextWrapping.Wrap });
			}

			return;
		}

		void Line(string label, string value) =>
			plan.Children.Add(new SelectableTextBlock { Text = $"{label}: {value}", TextWrapping = TextWrapping.Wrap });

		Line("Image", Json.Text(p, "Image") + (Json.Bool(p, "ImagePresent") == true ? " (on this machine)" : " (will be pulled)"));
		Line("Reachable", Json.Text(p, "Reachable"));
		var vols = Json.Strings(p, "Volumes");
		Line("Volumes", vols.Count > 0 ? string.Join("; ", vols) : "none");
		var env = Json.Strings(p, "EnvironmentNames");
		Line("Environment", env.Count > 0 ? string.Join(", ", env) : "none");
		Line("Restart policy", Json.Text(p, "RestartPolicy"));
		Line("Started", Json.Bool(p, "Start") == true ? "yes" : "no");
		plan.Children.Add(new TextBlock
		{
			Text = "It would be created. Create does it.",
			Margin = new Thickness(0, 6, 0, 0),
			HorizontalAlignment = HorizontalAlignment.Left,
		});
	}
}
