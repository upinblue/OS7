using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 6 — the destructive confirmation. SETUP-PLAN §3, Win2k's format
/// warning: `F` to go ahead, `ESC` to go back.
///
/// `F` and not ENTER, and that is the entire reason this screen exists as a
/// separate one. Every other screen in the flow advances on ENTER, so a person
/// walking through with the ENTER key would walk straight through this one too.
/// A key that is used nowhere else cannot be pressed by momentum.
/// </summary>
internal sealed class ConfirmScreen : Screen
{
    private readonly InstallPlan _plan;
    private readonly Disk _disk;

    public ConfirmScreen(InstallPlan plan, Disk disk)
    {
        _plan = plan;
        _disk = disk;
    }

    public override string Status => "F=Format   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        f.Body(3, 5, "Setup is about to write to the disk below.");

        int left = f.Left + 5;
        int width = Math.Min(70, f.BodyWidth - 10);
        f.Box(5, left, width, 5);
        f.Text(6, left + 3, $"{_disk.Name}   {_disk.Model}");
        f.Text(7, left + 3, $"{_disk.Size}   "
                            + (_disk.PartitionTable.Length == 0
                                ? "no partition table"
                                : $"{_disk.PartitionTable.ToUpperInvariant()}, "
                                  + $"{_disk.Partitions} partition"
                                  + (_disk.Partitions == 1 ? "" : "s")));
        f.Text(8, left + 3, _disk.StablePath);

        // Said plainly and said twice, because it is true twice: the partition
        // table goes, and so does everything the partitions held.
        f.Body(11, 5, "ALL DATA ON THIS DISK WILL BE LOST.", Slot.Brand);
        f.Body(13, 5, "Setup will create a new partition table, an EFI partition, a boot");
        f.Body(14, 5, "pool and "
                      + (_plan.Storage.Encrypt ? "an encrypted root pool." : "a root pool."));

        f.Body(16, 5, "To format this disk, press F.");
        f.Body(17, 5, "To choose a different disk, press ESC.");
    }

    public override Transition Handle(KeyPress key)
    {
        if (key.Is('F'))
        {
            // The last gate before anything is written, and the first place the
            // WHOLE plan is complete enough to check. §6.6 makes execution read
            // the plan and nothing else, so this is where an incomplete one has
            // to be caught - after here there is no screen left to catch it on.
            if (!_plan.Validate(out List<string> problems))
            {
                Log.Error("refusing to format: " + string.Join("; ", problems));
                return Transition.To(ErrorScreen.ForPlan(problems));
            }
            Log.Warn($"CONFIRMED: formatting {_disk.Name} ({_disk.StablePath})");
            return Transition.To(new ExecuteScreen(_plan));
        }
        if (key.Key == Key.Escape) return Transition.Back;
        return Transition.Stay;
    }
}
