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
///
/// IT IS THE GATE, NOT THE LAST GATE. It is the last screen before the one that
/// decides to write - the account and the mode still come after it, and the
/// writing starts at screen 10. So it refuses on the strength of what screens 3
/// to 5 collected and leaves the whole-plan check to ExecuteScreen.Start, which
/// is where "after here there is no screen left" is a true sentence.
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
        int width = f.BoxWidth;
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
            // WHAT SCREENS 3 TO 5 COLLECTED, and not one field more.
            //
            // This screen validated the WHOLE plan for exactly as long as it was
            // the last screen before the executor. Phase 3 put the account at 7
            // and the check was never narrowed, so pressing F asked for an
            // account nobody had been offered a chance to type: "no user account
            // was named" on the screen BEFORE the one that names it, with the
            // error screen the only thing past the confirmation. Screen 7 was
            // unreachable interactively for the whole of that commit.
            //
            // The whole-plan check did not move up, it moved DOWN, to
            // ExecuteScreen.Start - the moment §6.6 actually means, which is the
            // one after which there is no screen left to catch anything on. That
            // is not this one: nothing is written until screen 10.
            if (!_plan.ValidateThroughStorage(out List<string> problems))
            {
                Log.Error("refusing to format: " + string.Join("; ", problems));
                return Transition.To(ErrorScreen.ForPlan(problems));
            }
            Log.Warn($"CONFIRMED: formatting {_disk.Name} ({_disk.StablePath})");
            // Screen 7 next, NOT the executor. §3's numbering puts the
            // destructive confirmation at 6 and the account at 7, and the
            // writing does not begin until 10 - so this screen is the gate, and
            // the disk is still untouched while the account is typed.
            return Transition.To(new AccountScreen(_plan));
        }
        if (key.Key == Key.Escape) return Transition.Back;
        return Transition.Stay;
    }
}
