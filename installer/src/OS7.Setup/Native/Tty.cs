using System.Runtime.InteropServices;
using System.Text;

namespace OS7.Setup.Native;

/// <summary>
/// Which terminal a descriptor is, by name — and therefore what kind of surface
/// Setup is painting on.
///
/// SETUP-PLAN §2.7 splits the world in two and says Setup "must pick per
/// surface, not emit both":
///
///   the Linux VT     the palette IS the mechanism; a font can be loaded
///   serial or SSH    neither works. The palette cannot be set at all, and
///                    `setfont` on a serial line is meaningless.
///
/// Nothing can tell those apart from inside the process except the device name,
/// so this is where that fork starts. It also fixes something concrete: `setfont`
/// and `setvtrgb` without `-C` guess which console they mean, and under a systemd
/// unit they guess wrong — the first run of os7-setup on tty1 had setfont exit 71
/// while the console ended up in a font nobody asked for.
/// </summary>
internal static unsafe partial class Tty
{
    [LibraryImport("libc", SetLastError = true, EntryPoint = "ttyname_r")]
    private static partial int ttyname_r(int fd, byte* buf, nuint len);

    /// <summary>The device path behind `fd`, e.g. "/dev/tty1", or null.</summary>
    internal static string? Name(int fd)
    {
        const int size = 256;
        byte* buf = stackalloc byte[size];
        if (ttyname_r(fd, buf, size) != 0) return null;
        int n = 0;
        while (n < size && buf[n] != 0) n++;
        return Encoding.UTF8.GetString(buf, n);
    }

    /// <summary>
    /// True for /dev/tty1 … /dev/tty63 — a Linux virtual console.
    ///
    /// Deliberately NOT true for /dev/tty0 ("whatever is in front right now"):
    /// Setup owns one console and has to name it, and a font loaded onto
    /// "whichever" is a font loaded onto someone else's screen.
    /// </summary>
    internal static bool IsVirtualConsole(string? name)
    {
        if (name is null || !name.StartsWith("/dev/tty", StringComparison.Ordinal)) return false;
        string tail = name["/dev/tty".Length..];
        return tail.Length > 0 && int.TryParse(tail, out int n) && n >= 1 && n <= 63;
    }
}
