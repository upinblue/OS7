namespace OS7.Spike.Look;

/// <summary>
/// Four of the thirteen screens in SETUP-PLAN §3.1, transcribed as closely as a
/// cell buffer allows.
///
/// Chosen because between them they exercise everything the look depends on:
///
///     welcome   plain body text, the bullet, the status bar
///     disk      a single-line box with a selection row - black on light grey
///     layout    a box with a divider, i.e. ├ ┤ and a long horizontal run
///     copying   the progress bar, which is the ONLY place the brand blue is
///               used as a fill rather than as the title stripe
///
/// They are static. S1 asks whether the look works, not whether the flow does.
/// </summary>
internal static class Screens
{
    private const string Title = "OS/7 Setup";

    public static Screen Welcome(int cols, int rows)
    {
        var s = new Screen(cols, rows);
        s.Chrome(Title, "ENTER=Continue   R=Repair   F3=Quit");
        s.Body(3, 5, "Welcome to Setup.");
        s.Body(5, 5, "This portion of the Setup program prepares OS/7 to run on your");
        s.Body(6, 5, "computer.");
        s.Body(8, 7, "• To set up OS/7 now, press ENTER.");
        s.Body(10, 7, "• To repair or extend an existing OS/7 installation, press R.");
        s.Body(12, 7, "• To quit Setup without installing OS/7, press F3.");
        return s;
    }

    public static Screen Disk(int cols, int rows, int selected)
    {
        var s = new Screen(cols, rows);
        s.Chrome(Title, "ENTER=Select   F5=Advanced   F3=Quit");
        s.Body(3, 5, "Setup will install OS/7 on the disk selected below.");
        s.Body(5, 5, "Use the UP and DOWN ARROW keys to select a disk, then press ENTER.");

        string[] disks =
        {
            "  nvme0n1   SAMSUNG MZVL21T0HCLR-00B    953 GB   GPT, 3 partitions   ",
            "  sda       ATA WDC WD10EZEX-08W        931 GB   empty               ",
            "  sdb       SanDisk Cruzer Blade       14.4 GB   -- SETUP MEDIUM --  ",
        };

        int boxLeft = s.Left + 5;
        int boxWidth = 72;
        s.Box(7, boxLeft, boxWidth, disks.Length + 2);
        for (int i = 0; i < disks.Length; i++)
        {
            // Selection is black on light grey and spans the full inner width,
            // exactly as Win2k drew it - a highlighted row, not a highlighted word.
            bool sel = i == selected;
            int fg = sel ? Slot.Black : Slot.White;
            int bg = sel ? Slot.Grey : Slot.Field;
            s.Fill(8 + i, boxLeft + 1, boxWidth - 2, ' ', fg, bg);
            s.Text(8 + i, boxLeft + 1, disks[i], fg, bg);
        }
        s.Body(12, 5, "Every partition on the selected disk will be destroyed.");
        return s;
    }

    public static Screen Layout(int cols, int rows)
    {
        var s = new Screen(cols, rows);
        s.Chrome(Title, "ENTER=Continue   F1=Help   F3=Exit");
        s.Body(3, 5, "Setup will use the following storage settings:");

        string[] lines =
        {
            "   Disk:            nvme0n1  (953 GB)",
            "   Layout:          single disk",
            "   EFI partition:   512 MB   FAT32",
            "   Boot pool:       2 GB     ZFS  (bpool, GRUB-readable features)",
            "   Root pool:       950 GB   ZFS  (rpool)",
            "   Encryption:      LUKS2, aes-xts-plain64  (TPM2 + passphrase)",
            "   Swap:            zram, 50% of RAM (no swap on disk)",
        };

        int boxLeft = s.Left + 5;
        int boxWidth = 72;
        s.Box(5, boxLeft, boxWidth, lines.Length + 4);
        for (int i = 0; i < lines.Length; i++)
            s.Text(6 + i, boxLeft + 1, lines[i]);
        s.BoxDivider(6 + lines.Length, boxLeft, boxWidth);
        s.Text(7 + lines.Length, boxLeft + 3, "The settings are correct.");

        s.Body(6 + lines.Length + 4, 5, "If all the settings are correct, press ENTER.");
        return s;
    }

    public static Screen Copying(int cols, int rows, int percent)
    {
        var s = new Screen(cols, rows);
        s.Chrome(Title, "Please wait...");
        s.Body(6, 11, "Setup is copying files to the OS/7 boot environment.");

        int barLeft = s.Left + 11;
        const int barWidth = 52;              // 50 cells of fill inside the border
        s.Box(9, barLeft, barWidth, 3);
        int filled = (barWidth - 2) * percent / 100;

        // The fill is a FULL BLOCK on the brand background, not a coloured space.
        // Both would look the same today; the block is what keeps the bar visible
        // if the palette ever fails to load, which is a property worth having in
        // the one screen a user stares at for ten minutes.
        for (int i = 0; i < barWidth - 2; i++)
        {
            bool on = i < filled;
            s.Put(10, barLeft + 1 + i, on ? '█' : ' ',
                  on ? Slot.Brand : Slot.Field, Slot.Field);
        }

        string pct = $"{percent}%";
        s.Text(12, barLeft + (barWidth - pct.Length) / 2, pct);
        s.Body(14, 11, "Copying:  /usr/lib/aarch64-linux-gnu/libLLVM.so.20.1");
        return s;
    }

    /// <summary>
    /// Not from §3.1 - a glyph and colour test card, so a screendump can be read
    /// as evidence instead of as an impression. Every REQUIRED block from
    /// build/lib/psf.py appears here, plus one row per palette slot.
    /// </summary>
    public static Screen TestCard(int cols, int rows)
    {
        var s = new Screen(cols, rows);
        s.Chrome("OS/7 Setup - S1 test card", "F1..F12, arrows: see the key log");

        s.Body(3, 2, "Box Drawing    ┌─┬─┐ ├┼┤ └┴┘ │   "
                   + "╔═╦═╗ ╠╬╣ ╚╩╝ ║");
        s.Body(4, 2, "Block Elements █▓▒░ ▀▄ ▌▐");
        s.Body(5, 2, "German         ÄÖÜ äöü ß   Bullet •   Dash —   Euro €");

        // Two stacked boxes: the only way to see whether the cell tiling is
        // continuous. A one-pixel seam shows here and nowhere else.
        s.Box(7, s.Left + 2, 20, 3);
        s.Box(9, s.Left + 2, 20, 3);

        string[] names = { "0 black", "4 field #0057ad", "6 brand #1289ff", "7 grey #c0c0c0" };
        int[] slots = { Slot.Black, Slot.Field, Slot.Brand, Slot.Grey };
        for (int i = 0; i < slots.Length; i++)
        {
            s.Fill(13 + i, s.Left + 2, 24, ' ', Slot.White, slots[i]);
            s.Text(13 + i, s.Left + 28, names[i]);
        }
        return s;
    }
}
