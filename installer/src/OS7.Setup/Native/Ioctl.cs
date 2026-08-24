using System.Runtime.InteropServices;

namespace OS7.Setup.Native;

/// <summary>
/// The two ioctls Setup needs: how big the screen is, and which console it is on.
/// </summary>
internal static partial class Ioctl
{
    private const nuint TIOCGWINSZ = 0x5413;

    [StructLayout(LayoutKind.Sequential)]
    private struct WinSize
    {
        public ushort ws_row;
        public ushort ws_col;
        public ushort ws_xpixel;
        public ushort ws_ypixel;
    }

    [LibraryImport("libc", SetLastError = true, EntryPoint = "ioctl")]
    private static partial int ioctl_winsize(int fd, nuint request, out WinSize ws);

    /// <summary>
    /// Ask the kernel how many cells fit. Verified by spike S1: on a 1280x800
    /// framebuffer with the 16x32 Fixedsys PSF this returns exactly 80x25, which
    /// is the reference geometry §2.4 draws the mockups at.
    ///
    /// Asked of the OUTPUT descriptor, because that is the thing being painted.
    /// Asking stdin measures the wrong terminal whenever the two differ, which
    /// they do under `os7-setup --serial` and under the harness.
    /// </summary>
    internal static bool TryGetWindowSize(int fd, out int cols, out int rows)
    {
        cols = rows = 0;
        if (ioctl_winsize(fd, TIOCGWINSZ, out WinSize ws) != 0) return false;
        cols = ws.ws_col;
        rows = ws.ws_row;
        return cols > 0 && rows > 0;
    }
}
