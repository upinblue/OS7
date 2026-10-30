namespace OS7.App.Containers.Services;

/// <summary>Which polkit action a verb runs under (CONTAINERS-PLAN CT5).</summary>
public enum VerbClass
{
	/// <summary>Looks and changes nothing.</summary>
	Read,

	/// <summary>Starts, stops, creates — reversible by another verb.</summary>
	Operate,

	/// <summary>Deletes. polkit asks every time.</summary>
	Destroy,

	/// <summary>Makes this machine a container host. polkit asks every time, in its own words.</summary>
	Install,
}

/// <summary>One verb of the container window's table.</summary>
/// <param name="Name">The verb as Invoke-OS7ContainerVerb knows it.</param>
/// <param name="Class">Which helper, and so which polkit action, runs it.</param>
/// <param name="TakesInput">Whether it reads JSON on standard input.</param>
public sealed record ContainerVerb(string Name, VerbClass Class, bool TakesInput = false);

/// <summary>
/// Every verb this window sends.
/// </summary>
/// <remarks>
/// <para>
/// THE TABLE IS THE MODULE'S, AND THIS IS ITS MIRROR. Invoke-OS7ContainerVerb in
/// powershell/OS7/OS7.Container.ps1 decides what each verb does and which class
/// it is; this file says which of those the window uses. A mirror with nothing
/// watching it is #66, so installer/testing/check-gui-logic.py requires every
/// verb here to exist there WITH THE SAME CLASS — a button cannot ask for a verb
/// the helper does not have, or send a deleting verb to the helper that
/// remembers the password.
/// </para>
/// <para>
/// Written as one <c>new("name", VerbClass.X)</c> per line on purpose: that is
/// the shape the check reads.
/// </para>
/// </remarks>
public static class ContainerVerbs
{
	public static readonly ContainerVerb Host = new("host", VerbClass.Read);
	public static readonly ContainerVerb Attention = new("attention", VerbClass.Read);
	public static readonly ContainerVerb List = new("list", VerbClass.Read);
	public static readonly ContainerVerb Log = new("log", VerbClass.Read);
	public static readonly ContainerVerb Images = new("images", VerbClass.Read);
	public static readonly ContainerVerb ImagesCheck = new("images-check", VerbClass.Read);
	public static readonly ContainerVerb Volumes = new("volumes", VerbClass.Read);
	public static readonly ContainerVerb VolumeVersions = new("volume-versions", VerbClass.Read);
	public static readonly ContainerVerb Networks = new("networks", VerbClass.Read);
	public static readonly ContainerVerb Apps = new("apps", VerbClass.Read);
	public static readonly ContainerVerb Unused = new("unused", VerbClass.Read);
	public static readonly ContainerVerb Validate = new("validate", VerbClass.Read, TakesInput: true);

	public static readonly ContainerVerb Start = new("start", VerbClass.Operate);
	public static readonly ContainerVerb Stop = new("stop", VerbClass.Operate);
	public static readonly ContainerVerb Restart = new("restart", VerbClass.Operate);
	public static readonly ContainerVerb AppStart = new("app-start", VerbClass.Operate);
	public static readonly ContainerVerb AppStop = new("app-stop", VerbClass.Operate);
	public static readonly ContainerVerb Create = new("create", VerbClass.Operate, TakesInput: true);

	public static readonly ContainerVerb Remove = new("remove", VerbClass.Destroy);
	public static readonly ContainerVerb ImageRemove = new("image-remove", VerbClass.Destroy);
	public static readonly ContainerVerb VolumeRemove = new("volume-remove", VerbClass.Destroy);
	public static readonly ContainerVerb NetworkRemove = new("network-remove", VerbClass.Destroy);
	public static readonly ContainerVerb Cleanup = new("cleanup", VerbClass.Destroy, TakesInput: true);

	public static readonly ContainerVerb InstallHost = new("install-host", VerbClass.Install);

	public static IReadOnlyList<ContainerVerb> All { get; } = new[]
	{
		Host, Attention, List, Log, Images, ImagesCheck, Volumes, VolumeVersions, Networks, Apps, Unused, Validate,
		Start, Stop, Restart, AppStart, AppStop, Create,
		Remove, ImageRemove, VolumeRemove, NetworkRemove, Cleanup,
		InstallHost,
	};

	/// <summary>
	/// The helper a verb goes to when the window is signed in through polkit.
	/// </summary>
	/// <remarks>
	/// One helper per polkit action, because polkit decides by PATH: one action
	/// remembers the password for a few minutes, one asks every time before
	/// anything is removed, and one asks every time before the engine is
	/// installed — each in its own words. The helper refuses a verb of the wrong
	/// class too — this is the first wall, not the only one.
	/// </remarks>
	public static string HelperFor(ContainerVerb verb) => verb.Class switch
	{
		VerbClass.Destroy => "os7-container-helper-destroy",
		VerbClass.Install => "os7-container-helper-install",
		_ => "os7-container-helper",
	};
}
