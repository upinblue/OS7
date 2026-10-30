using System.Text.Json;
using OS7.App.Containers.Model;
using OS7.App.Containers.Services;
using OS7.App.Containers.ViewModels;
using OS7.Shell;

namespace OS7.App.Containers;

/// <summary>
/// Every decision this window makes, asked with no display, no PowerShell and
/// no engine.
/// </summary>
/// <remarks>
/// <para>
/// THE LIST IS SHORT ON PURPOSE. What a container's state is, who can reach a
/// port, what a clean-up may remove and whether a tag moved on are the cmdlets'
/// and are checked by installer/testing/check-container-logic.py against a fake
/// engine. What is left here is what a WINDOW decides: which channel and which
/// helper a verb goes through, how an argument is quoted, how an answer is read,
/// what each column shows, how a property is labelled, and how the dialog's text
/// fields become a description.
/// </para>
/// </remarks>
public static class SelfTest
{
	private static int _pass;
	private static readonly List<string> Failures = new();

	public static int Run()
	{
		Console.Error.WriteLine("OS/7 Containers self-test");

		Verbs();
		Quoting();
		Answers();
		Access();
		Cells();
		Properties();
		Form();
		Summary();

		Console.Error.WriteLine();
		Console.Error.WriteLine($"  {_pass} ok, {Failures.Count} failed");
		foreach (var failure in Failures)
		{
			Console.Error.WriteLine($"    FAILED: {failure}");
		}

		return Failures.Count == 0 ? 0 : 1;
	}

	private static void Check(string what, bool ok, string detail = "")
	{
		Console.Error.WriteLine($"      {(ok ? "ok  " : "FAIL")}  {what}" + (detail.Length > 0 ? $"   [{detail}]" : string.Empty));
		if (ok)
		{
			_pass++;
		}
		else
		{
			Failures.Add(what);
		}
	}

	private static JsonElement J(string json)
	{
		using var doc = JsonDocument.Parse(json);
		return doc.RootElement.Clone();
	}

	private static void Section(string title)
	{
		Console.Error.WriteLine();
		Console.Error.WriteLine($"  {title}");
	}

	// ----------------------------------------------------------------- verbs

	private static void Verbs()
	{
		Section("Which helper, and so which polkit action, a verb reaches");

		var destroy = ContainerVerbs.All.Where(v => v.Class == VerbClass.Destroy).ToArray();
		Check("every deleting verb is Destroy",
			destroy.Select(v => v.Name).OrderBy(n => n).SequenceEqual(new[] { "cleanup", "image-remove", "network-remove", "remove", "volume-remove" }),
			string.Join(", ", destroy.Select(v => v.Name)));
		Check("a Destroy verb goes to the helper polkit asks EVERY time",
			destroy.All(v => ContainerVerbs.HelperFor(v) == "os7-container-helper-destroy"));
		Check("installing the engine goes to its own helper, which polkit asks every time in its own words",
			ContainerVerbs.All.Where(v => v.Class == VerbClass.Install).Select(v => v.Name).SequenceEqual(new[] { "install-host" })
			&& ContainerVerbs.HelperFor(ContainerVerbs.InstallHost) == "os7-container-helper-install");
		Check("installing goes through its helper EVEN when not signed in — there is no engine to sign in to (found on a machine)",
			ContainerChannel.UsesHelper(ContainerVerbs.InstallHost, ChannelMode.Direct)
			&& !ContainerChannel.UsesHelper(ContainerVerbs.List, ChannelMode.Direct)
			&& !ContainerChannel.UsesHelper(ContainerVerbs.Remove, ChannelMode.Direct)
			&& ContainerChannel.UsesHelper(ContainerVerbs.List, ChannelMode.Helper));
		Check("every other verb goes to the helper that may remember the password",
			ContainerVerbs.All.Where(v => v.Class is VerbClass.Read or VerbClass.Operate).All(v => ContainerVerbs.HelperFor(v) == "os7-container-helper"));
		Check("verb names are unique",
			ContainerVerbs.All.Select(v => v.Name).Distinct().Count() == ContainerVerbs.All.Count);
		Check("the verbs that carry a description read it on standard input",
			ContainerVerbs.All.Where(v => v.TakesInput).Select(v => v.Name).OrderBy(n => n).SequenceEqual(new[] { "cleanup", "create", "validate" }));
		Check("a helper is always under /usr/libexec",
			PolkitHelper.PathFor("os7-container-helper") == "/usr/libexec/os7-container-helper");

		var refused = false;
		try
		{
			PolkitHelper.PathFor("../../bin/sh");
		}
		catch (ArgumentException)
		{
			refused = true;
		}

		Check("a helper name that is not os7-… is refused, so no path can be smuggled in", refused);
	}

	// --------------------------------------------------------------- quoting

	private static void Quoting()
	{
		Section("An argument cannot become PowerShell");

		var hostile = "'; Remove-Item -Recurse / #";
		var script = ContainerChannel.ScriptFor(ContainerVerbs.Start, new[] { hostile });
		Check("it travels inside a single-quoted here-string",
			script.Contains("@'\n" + hostile + "\n'@", StringComparison.Ordinal), script);
		Check("and the verb is the table's, not the argument's",
			script.EndsWith("Invoke-OS7ContainerVerb -Verb 'start' -Argument $a", StringComparison.Ordinal));
		Check("no arguments is an empty array, not a missing one",
			ContainerChannel.ScriptFor(ContainerVerbs.List, Array.Empty<string>()).Contains("$a = @(); ", StringComparison.Ordinal));

		var refused = false;
		try
		{
			ContainerChannel.ScriptFor(ContainerVerbs.Start, new[] { "web\n'@; whoami" });
		}
		catch (ArgumentException)
		{
			refused = true;
		}

		Check("an argument with a line break — the only way out of a here-string — is refused", refused);
		Check("the helper is given the verb first, then the arguments",
			ContainerChannel.HelperArguments(ContainerVerbs.Log, new[] { "web", "300" }).SequenceEqual(new[] { "log", "web", "300" }));
	}

	// --------------------------------------------------------------- answers

	private static void Answers()
	{
		Section("Reading a verb's answer");

		var one = ContainerChannel.Parse(new ShellResult(0, "[{\"Name\":\"web\"}]\n", string.Empty));
		Check("an array of one is one object", one.Ok && one.Items.Count == 1 && Json.Text(one.Items[0], "Name") == "web");
		var none = ContainerChannel.Parse(new ShellResult(0, "[]", string.Empty));
		Check("[] is nothing, and not an error", none.Ok && none.Items.Count == 0);
		var empty = ContainerChannel.Parse(new ShellResult(0, "  ", string.Empty));
		Check("no output at all is nothing too", empty.Ok && empty.Items.Count == 0);
		var bare = ContainerChannel.Parse(new ShellResult(0, "{\"Name\":\"web\"}", string.Empty));
		Check("a bare object is refused: every verb answers an array", !bare.Ok);
		var refused = ContainerChannel.Parse(new ShellResult(1, string.Empty,
			"Start-OS7Container must run as root: it starts a container.\nAt /usr/local/share/x.ps1:12 char:3\n+ throw"));
		Check("a refusal is the cmdlet's sentence, without PowerShell's account of its source",
			!refused.Ok && refused.Error == "Start-OS7Container must run as root: it starts a container.", refused.Error ?? "");
	}

	// ---------------------------------------------------------------- access

	private static void Access()
	{
		Section("What Get-OS7ContainerHost's Access lets the window do");

		Check("Root draws the engine", MainWindowViewModel.AccessFrom("Root") == AccessState.Ready);
		Check("an Operator draws the engine", MainWindowViewModel.AccessFrom("Operator") == AccessState.Ready);
		Check("Denied offers Sign in…", MainWindowViewModel.AccessFrom("Denied") == AccessState.NeedsSignIn);
		Check("NoEngine says how to install one", MainWindowViewModel.AccessFrom("NoEngine") == AccessState.NoEngine);
		var installed = new VerbAnswer(new[] { J("{\"Outcome\":\"Installed\",\"Engine\":\"29.1.3\",\"Packages\":[\"docker.io 29.1.3-0ubuntu4.1\"],"
			+ "\"Checks\":[{\"Check\":\"the engine answers this session\",\"Ok\":true},{\"Check\":\"the engine logs to the journal\",\"Ok\":false}]}") }, null);
		var summary = MainWindowViewModel.InstallSummary(installed);
		Check("setting up the engine reports its own read-backs, a failed one as NOT",
			summary.StartsWith("Installed: Docker 29.1.3", StringComparison.Ordinal)
			&& summary.Contains("ok  the engine answers", StringComparison.Ordinal)
			&& summary.Contains("NOT  the engine logs", StringComparison.Ordinal), summary);
		Check("a word this window does not know is a failure, not a guess", MainWindowViewModel.AccessFrom("Hibernating") == AccessState.Failed);

		var host = J("{\"Access\":\"Operator\",\"EngineVersion\":\"29.1.3\",\"ApiVersion\":\"1.52\",\"Containers\":5,"
			+ "\"ContainersRunning\":3,\"ContainersNeedingAttention\":1,\"Pool\":\"rpool\",\"PoolCapacity\":41,\"PoolLevel\":\"Normal\"}");
		var line = MainWindowViewModel.StatusLine(host, ChannelMode.Direct);
		Check("the status line is the host's own fields",
			line.Contains("Docker 29.1.3, API 1.52", StringComparison.Ordinal) && line.Contains("3 of 5 containers running", StringComparison.Ordinal)
			&& line.Contains("1 need attention", StringComparison.Ordinal) && line.Contains("41% full (Normal)", StringComparison.Ordinal)
			&& line.EndsWith("as a container operator", StringComparison.Ordinal), line);
		Check("and through the helper it says so",
			MainWindowViewModel.StatusLine(host, ChannelMode.Helper).EndsWith("signed in through polkit", StringComparison.Ordinal));
		var bare = MainWindowViewModel.StatusLine(J("{\"Access\":\"NoEngine\"}"), ChannelMode.Direct);
		Check("with no engine, nothing is claimed about one", !bare.Contains("Docker", StringComparison.Ordinal), bare);
	}

	// ----------------------------------------------------------------- cells

	private static void Cells()
	{
		Section("Each column shows the cmdlet's word");

		var c = new ObjectRow(NodeKind.Containers, J("{\"Name\":\"web\",\"State\":\"RestartLoop\",\"NeedsAttention\":true,"
			+ "\"Image\":\"nginx:1.27\",\"Reachable\":\"8080 → 80/tcp · this machine only\",\"RestartPolicy\":\"always\"}"));
		Check("a container's row: name, state, image, who can reach it, restart policy",
			c.C0 == "web" && c.C1 == "RestartLoop" && c.C2 == "nginx:1.27" && c.C3.EndsWith("this machine only", StringComparison.Ordinal) && c.C4 == "always");
		Check("and it is marked as needing attention from the cmdlet's own field", c.NeedsAttention);

		var asked = J("{\"UpdateChecked\":true,\"UpdateAvailable\":true}");
		var current = J("{\"UpdateChecked\":true,\"UpdateAvailable\":false}");
		var unknown = J("{\"UpdateChecked\":true,\"UpdateAvailable\":null}");
		var notAsked = J("{\"UpdateChecked\":false,\"UpdateAvailable\":null}");
		Check("registry: a moved tag", Columns.Update(asked) == "Newer image available");
		Check("registry: current", Columns.Update(current) == "Current");
		Check("registry: asked and not answered is said, not called current", Columns.Update(unknown) == "Could not be checked");
		Check("registry: not asked is blank — no claim", Columns.Update(notAsked).Length == 0);

		var dangling = new ObjectRow(NodeKind.Images, J("{\"Name\":\"<none> (64616e676c69)\",\"Id\":\"sha256:abc\",\"Size\":1536}"));
		Check("an image with no name is acted on by its Id", dangling.Name == "sha256:abc");
		Check("and its size reads as a person reads it", dangling.C1 == "1.5 KiB", dangling.C1);

		var app = new ObjectRow(NodeKind.Applications, J("{\"Name\":\"shop\",\"State\":\"Partial\",\"Running\":2,\"Total\":3,\"Services\":[\"db\",\"web\",\"worker\"]}"));
		Check("an application: 2 of 3 running, its services joined", app.C2 == "2 of 3" && app.C3 == "db, web, worker", $"{app.C2} | {app.C3}");

		var builtIn = new ObjectRow(NodeKind.Networks, J("{\"Name\":\"bridge\",\"Builtin\":true}"));
		Check("a built-in network says so", builtIn.C4 == "Yes");
		var unread = new ObjectRow(NodeKind.Volumes, J("{\"Name\":\"v\",\"BackedUp\":null}"));
		Check("a volume whose backup could not be read says Unknown, never No", unread.C3 == "Unknown", unread.C3);

		Check("sizes: bytes, KiB, MiB, and nothing for unknown",
			Json.Size(0) == "0 B" && Json.Size(1536) == "1.5 KiB" && Json.Size(60_000_000) == "57.2 MiB" && Json.Size(null).Length == 0 && Json.Size(-1).Length == 0);
		Check("every node has five column headers",
			Enum.GetValues<NodeKind>().All(k => Columns.For(k).Count == Columns.Count));
	}

	// ------------------------------------------------------------ properties

	private static void Properties()
	{
		Section("The details pane renders whatever the cmdlet sent (CT11)");

		var rows = PropertyGrid.Render(J("{\"Name\":\"web\",\"NeedsAttention\":false,\"SomethingNextRelease\":\"x\","
			+ "\"Ports\":[{\"Text\":\"8080 → 80/tcp · all networks\"}],\"Volumes\":[\"a\",\"b\"],\"Reason\":null,"
			+ "\"Labels\":{\"com.docker.compose.project\":\"shop\"},\"Size\":2048,\"Id\":\"abc\"}"));
		string Value(string label) => rows.FirstOrDefault(r => r.Label == label)?.Value ?? "(absent)";

		Check("a property this window has never heard of is shown, under its own name made readable",
			Value("Something next release") == "x");
		Check("in the order the cmdlet sent", rows.Count == 9 && rows[0].Label == "Name" && rows[^1].Label == "ID");
		Check("a boolean is Yes or No", Value("Needs attention") == "No");
		Check("null is a dash, not an empty line", Value("Reason") == "—");
		Check("values in an array are one line", Value("Volumes") == "a, b");
		Check("objects in an array are one line each, and one with a Text is shown by it",
			Value("Ports") == "8080 → 80/tcp · all networks", Value("Ports"));
		Check("an object is one line per key", Value("Labels") == "com.docker.compose.project = shop");
		Check("a size is shown both ways", Value("Size") == "2.0 KiB (2048 bytes)", Value("Size"));
	}

	// ------------------------------------------------------------------ form

	private static void Form()
	{
		Section("The create dialog's fields become a description, and nothing more");

		var ports = CreateForm.Ports("8080:80\n\n 5353:53/udp \n10.0.0.5:8443:443\n[::1]:9000:9000\n", thisMachineOnly: true);
		Check("this machine only: a port with no address gets 127.0.0.1",
			ports[0] == "127.0.0.1:8080:80" && ports[1] == "127.0.0.1:5353:53/udp", string.Join(" | ", ports));
		Check("a port that names an address is left as it was", ports[2] == "10.0.0.5:8443:443" && ports[3] == "[::1]:9000:9000");
		Check("blank lines are not ports", ports.Count == 4);
		Check("and unticked, Docker's own meaning stands", CreateForm.Ports("8080:80", thisMachineOnly: false)[0] == "8080:80");

		var env = CreateForm.Environment("POSTGRES_PASSWORD=s3=cret\nTZ=Europe/Berlin\n\nNOVALUE\n");
		Check("NAME=value, with '=' allowed in the value", env.Values["POSTGRES_PASSWORD"] == "s3=cret" && env.Values["TZ"] == "Europe/Berlin");
		Check("a line with no '=' is said back, not guessed at", env.Problems.Count == 1 && env.Problems[0].Contains("line 4", StringComparison.Ordinal));

		var json = CreateForm.ToJson(" web ", "nginx:1.27", ports, CreateForm.Lines("data:/srv"), env.Values, restartAutomatically: true, start: false);
		var d = J(json);
		Check("the description: names trimmed, the policy and start as the cmdlet's parameters",
			Json.Text(d, "Name") == "web" && Json.Text(d, "RestartPolicy") == "unless-stopped" && Json.Bool(d, "NoStart") == true, json);
		Check("the environment travels in it — on standard input, never a command line",
			Json.Get(d, "Environment") is { } e && Json.Text(e, "TZ") == "Europe/Berlin");
	}

	// --------------------------------------------------------------- summary

	private static void Summary()
	{
		Section("What an action said, under the list");

		var ok = new VerbAnswer(new[] { J("{\"Name\":\"web\",\"Outcome\":\"Started\",\"State\":\"Running\",\"Reason\":null}") }, null);
		Check("outcome and state, in the cmdlet's words", MainWindowViewModel.Summarise("Start", ok) == "web: Started, now Running",
			MainWindowViewModel.Summarise("Start", ok));
		var exited = new VerbAnswer(new[] { J("{\"Name\":\"job\",\"Outcome\":\"Exited\",\"State\":\"Failed\",\"Reason\":\"Its process ended with exit code 2.\"}") }, null);
		Check("a start that died at once reads as what it is",
			MainWindowViewModel.Summarise("Start", exited) == "job: Exited, now Failed. Its process ended with exit code 2.");
		var dismissed = new VerbAnswer(Array.Empty<JsonElement>(), "x", Dismissed: true);
		Check("a closed polkit dialog is not called a failure", MainWindowViewModel.Summarise("Remove", dismissed).Contains("not done", StringComparison.Ordinal));
		var refused = new VerbAnswer(Array.Empty<JsonElement>(), "Could not remove container 'web' — the engine answered 409: …");
		Check("a refusal is passed through whole", MainWindowViewModel.Summarise("Remove", refused).StartsWith("Could not remove", StringComparison.Ordinal));
	}
}
