using OS7.Setup.Diagnostics;
using OS7.Setup.Model;
using OS7.Setup.Tui;
using OS7.Setup.Tui.Widgets;

namespace OS7.Setup.Screens;

/// <summary>
/// Screen 5 — Storage layout. SETUP-PLAN §3.1, the MS-DOS 6.22 homage.
///
/// Most of what it shows is not adjustable, and that is the design rather than
/// an omission. The ESP is 512 MB FAT32 because UEFI reads FAT and nothing else
/// (L1). `bpool` exists because GRUB reads ZFS read-only (D1). Encryption is
/// LUKS2 under ZFS because Intune only recognises dm-crypt (D3). Swap is zram
/// because swap on a zvol still deadlocks upstream (D4). Offering a choice
/// where the answer is forced would be a menu that teaches the wrong thing.
///
/// So the screen SHOWS the layout and lets exactly two things be changed:
/// whether to encrypt, and the passphrase.
/// </summary>
internal sealed class LayoutScreen : Screen
{
    private enum Setting { Encryption, Passphrase, Accept }

    private readonly InstallPlan _plan;
    private readonly Disk _disk;
    private readonly TextBox _pass = new() { Masked = true };
    private readonly TextBox _again = new() { Masked = true };
    private Setting _row = Setting.Accept;
    private bool _entering;      // true while a passphrase is being typed
    private bool _second;        // …and true while it is being confirmed
    private string? _note;

    public LayoutScreen(InstallPlan plan, Disk disk)
    {
        _plan = plan;
        _disk = disk;
    }

    public override string Status => _entering
        ? "ENTER=Confirm   ESC=Cancel"
        : "ENTER=Continue   ↑↓=Select   ESC=Back   F3=Quit";

    public override void Draw(Frame f)
    {
        if (_entering) { DrawPassphrase(f); return; }

        f.Body(3, 5, "Setup will use the following storage settings:");

        int left = f.Left + 5;
        int width = f.BoxWidth;
        StoragePlan s = _plan.Storage;

        long rest = _disk.Bytes - (long)s.EfiMiB * 1024 * 1024 - (long)s.BpoolGiB * 1024 * 1024 * 1024;
        f.Box(5, left, width, 10);
        Fixed(f, 6, left, "Disk:", $"{_disk.Name}  ({_disk.Size})");
        Fixed(f, 7, left, "Layout:", "single disk");
        Fixed(f, 8, left, "EFI partition:", $"{s.EfiMiB} MB   FAT32");
        Fixed(f, 9, left, "Boot pool:", $"{s.BpoolGiB} GB     ZFS  (bpool, GRUB-readable features)");
        Fixed(f, 10, left, "Root pool:", $"{Human(rest)}   ZFS  (rpool)");
        Row(f, 11, left, width, Setting.Encryption, "Encryption:",
            s.Encrypt ? "LUKS2, aes-xts-plain64  (passphrase)" : "none");
        Row(f, 12, left, width, Setting.Passphrase, "Passphrase:",
            !s.Encrypt ? "-- not required --"
                       : s.Passphrase is null ? "-- not set --" : "set");
        Fixed(f, 13, left, "Swap:", "zram, 50% of RAM (no swap on disk)");
        f.Divider(14, left, width);
        Row(f, 15, left, width, Setting.Accept, "The settings are correct.", "");

        f.Body(18, 5, "If all the settings are correct, press ENTER.");
        f.Body(20, 5, "To change a setting, press the UP or DOWN ARROW keys to select it.");
        if (_note is not null) f.Body(22, 5, _note, Slot.Brand);
    }

    private void DrawPassphrase(Frame f)
    {
        f.Body(3, 5, _second ? "Type the passphrase again to confirm it."
                             : "Type a passphrase for the encrypted disk.");
        int left = f.Left + 5;
        int width = f.BoxWidth;

        f.Box(6, left, width, 3);
        (_second ? _again : _pass).Draw(f, 7, left + 1, width - 2, focused: true);

        // The consequence, in the place where it can still be acted on. There is
        // no recovery key escrow yet - U8 in the release plan - so on this
        // machine a forgotten passphrase really is the end of the data.
        f.Body(10, 5, "You will be asked for this passphrase every time the computer starts,");
        f.Body(11, 5, "unless Setup can seal it to the TPM.");
        f.Body(13, 5, "There is no way to recover the data if you forget it.", Slot.Brand);
        if (_note is not null) f.Body(15, 5, _note, Slot.Brand);
    }

    private static void Fixed(Frame f, int row, int left, string label, string value)
    {
        f.Text(row, left + 3, label);
        f.Text(row, left + 3 + 18, value);
    }

    private void Row(Frame f, int row, int left, int width, Setting which, string label, string value)
    {
        bool selected = _row == which;
        int fg = selected ? Slot.Black : Slot.White;
        int bg = selected ? Slot.Grey : Slot.Field;
        f.Fill(row, left + 1, width - 2, ' ', fg, bg);
        f.Text(row, left + 3, label, fg, bg);
        if (value.Length > 0) f.Text(row, left + 3 + 18, value, fg, bg);
    }

    private static string Human(long bytes) =>
        bytes >= 1_000_000_000_000L ? $"{bytes / 1e12:0.##} TB" : $"{bytes / 1e9:0.##} GB";

    public override Transition Handle(KeyPress key)
    {
        return _entering ? HandlePassphrase(key) : HandleSummary(key);
    }

    private Transition HandleSummary(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Up:
                _row = _row == Setting.Encryption ? Setting.Accept : _row - 1;
                return Transition.Redraw;

            case Key.Down:
                _row = _row == Setting.Accept ? Setting.Encryption : _row + 1;
                return Transition.Redraw;

            case Key.Enter when _row == Setting.Encryption:
                _plan.Storage.Encrypt = !_plan.Storage.Encrypt;
                if (!_plan.Storage.Encrypt) _plan.Storage.Passphrase = null;
                Log.Info($"encryption: {_plan.Storage.Encrypt}");
                _note = _plan.Storage.Encrypt ? null
                    : "Without encryption this machine cannot pass Intune's device-encryption rule.";
                return Transition.Redraw;

            case Key.Enter when _row == Setting.Passphrase:
                if (!_plan.Storage.Encrypt)
                {
                    _note = "Turn encryption on first.";
                    return Transition.Redraw;
                }
                StartPassphrase();
                return Transition.Redraw;

            case Key.Enter:
                if (_plan.Storage.Encrypt && _plan.Storage.Passphrase is null)
                {
                    // The one place the flow refuses to move on. Everything else
                    // on this screen has a working default; a passphrase cannot.
                    _note = "Set a passphrase before continuing.";
                    _row = Setting.Passphrase;
                    return Transition.Redraw;
                }
                return Transition.To(new ConfirmScreen(_plan, _disk));

            case Key.Escape:
                return Transition.Back;

            default:
                return Transition.Stay;
        }
    }

    private void StartPassphrase()
    {
        _pass.Clear();
        _again.Clear();
        _entering = true;
        _second = false;
        _note = null;
    }

    private Transition HandlePassphrase(KeyPress key)
    {
        switch (key.Key)
        {
            case Key.Escape:
                _entering = false;
                _pass.Clear();
                _again.Clear();
                _note = null;
                return Transition.Redraw;

            case Key.Enter when !_second:
                if (_pass.Length < MinimumLength)
                {
                    _note = $"Use at least {MinimumLength} characters.";
                    return Transition.Redraw;
                }
                _second = true;
                _note = null;
                return Transition.Redraw;

            case Key.Enter:
                // Compared, not trusted. There is no second chance at the boot
                // prompt and no recovery key (U8), so a typo here is the data.
                if (_again.Value != _pass.Value)
                {
                    _note = "The two entries do not match. Try again.";
                    _second = false;
                    _pass.Clear();
                    _again.Clear();
                    return Transition.Redraw;
                }
                _plan.Storage.Passphrase = _pass.Value;
                _pass.Clear();
                _again.Clear();
                _entering = false;
                _row = Setting.Accept;
                // Length only. The value itself never reaches the log.
                // LiveOnly - see Log.LiveOnly. This is the line that made the
                // distinction necessary.
                Log.LiveOnly($"passphrase set ({_plan.Storage.Passphrase!.Length} characters)");
                _note = null;
                return Transition.Redraw;

            default:
                return (_second ? _again : _pass).Handle(key)
                    ? Transition.Redraw : Transition.Stay;
        }
    }

    // Not a policy, a floor. cryptsetup accepts anything; eight characters is
    // the point below which a passphrase is not protecting a disk that will be
    // carried out of a building.
    private const int MinimumLength = 8;
}
