using System.Runtime.InteropServices;

namespace OS7.Spike.Look;

/// <summary>
/// Raw terminal mode and window size, straight out of libc.
///
/// SETUP-PLAN §6.2 commits os7-setup to exactly this - "C# + DllImport("libc")
/// tcgetattr/tcsetattr" - and §6.4 rejects Terminal.Gui partly on the strength
/// of it being small. S1 is where "small" gets tested against a real VT.
///
/// BUILD-NOTES #22 is the trap: c_cc MUST be a `fixed byte[32]`, not a
/// `byte[]` with [MarshalAs(ByValArray)]. LibraryImport marshals blittable
/// types only, and a managed array in a struct is not blittable - the failure
/// is a build error (SYSLIB1051), which is the good case, but the shape of the
/// struct is what makes it go away.
/// </summary>
internal static unsafe partial class Termios
{
    // struct termios on glibc/Linux: 4 tcflag_t, cc_t c_line, cc_t c_cc[32],
    // then two speed_t. NCCS is 32 on Linux for every architecture OS/7 targets.
    [StructLayout(LayoutKind.Sequential)]
    internal struct TermiosStruct
    {
        public uint c_iflag;
        public uint c_oflag;
        public uint c_cflag;
        public uint c_lflag;
        public byte c_line;
        public fixed byte c_cc[32];
        public uint c_ispeed;
        public uint c_ospeed;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct WinSize
    {
        public ushort ws_row;
        public ushort ws_col;
        public ushort ws_xpixel;
        public ushort ws_ypixel;
    }

    private const int TCSANOW = 0;
    private const int TIOCGWINSZ = 0x5413;

    // Input flags to clear, and why each one would corrupt a keypress:
    //   ICRNL  - would turn the CR that Enter sends into LF
    //   IXON   - would eat Ctrl-S / Ctrl-Q as flow control
    //   INLCR, IGNCR, BRKINT, ISTRIP, INPCK - classic cfmakeraw set
    private const uint IGNBRK = 0x0001, BRKINT = 0x0002, PARMRK = 0x0008,
                       ISTRIP = 0x0020, INLCR = 0x0040, IGNCR = 0x0080,
                       ICRNL = 0x0100, IXON = 0x0400;
    private const uint OPOST = 0x0001;
    // ECHO off so a keypress does not paint itself over the frame; ICANON off
    // so reads return per keystroke instead of per line; ISIG off so F3=Quit is
    // a key the program decides about rather than a signal that kills it.
    private const uint ISIG = 0x0001, ICANON = 0x0002, ECHO = 0x0008, IEXTEN = 0x8000;
    private const uint CSIZE = 0x0030, PARENB = 0x0100, CS8 = 0x0030;

    [LibraryImport("libc", SetLastError = true)]
    private static partial int tcgetattr(int fd, out TermiosStruct t);

    [LibraryImport("libc", SetLastError = true)]
    private static partial int tcsetattr(int fd, int optionalActions, in TermiosStruct t);

    [LibraryImport("libc", SetLastError = true, EntryPoint = "ioctl")]
    private static partial int ioctl_winsize(int fd, nuint request, out WinSize ws);

    internal static bool TryGetWindowSize(int fd, out int cols, out int rows)
    {
        cols = rows = 0;
        if (ioctl_winsize(fd, TIOCGWINSZ, out WinSize ws) != 0)
            return false;
        cols = ws.ws_col;
        rows = ws.ws_row;
        return cols > 0 && rows > 0;
    }

    /// <summary>Enter raw mode. Returns the previous settings for restoring.</summary>
    internal static TermiosStruct MakeRaw(int fd)
    {
        if (tcgetattr(fd, out TermiosStruct saved) != 0)
            throw new IOException($"tcgetattr(fd {fd}) failed: errno {Marshal.GetLastPInvokeError()}");

        TermiosStruct raw = saved;
        raw.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
        raw.c_oflag &= ~OPOST;
        raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
        raw.c_cflag &= ~(CSIZE | PARENB);
        raw.c_cflag |= CS8;
        // VMIN = 1, VTIME = 0: block until at least one byte, never time out on
        // a partial escape sequence. The decoder handles the rest.
        raw.c_cc[6] = 1;    // VMIN
        raw.c_cc[5] = 0;    // VTIME

        if (tcsetattr(fd, TCSANOW, in raw) != 0)
            throw new IOException($"tcsetattr(fd {fd}) failed: errno {Marshal.GetLastPInvokeError()}");
        return saved;
    }

    internal static void Restore(int fd, TermiosStruct saved) => tcsetattr(fd, TCSANOW, in saved);

    [LibraryImport("libc", SetLastError = true, EntryPoint = "read")]
    private static partial nint sys_read(int fd, byte* buf, nuint count);

    /// <summary>
    /// One byte from `fd`, or -1 at end of input.
    ///
    /// read(2) directly, and NOT Console.OpenStandardInput(). .NET's console
    /// stream carries its own terminal handling - it applies termios settings of
    /// its own on first use and interprets the result - and with it in the path
    /// this returned exactly one byte and then reported end of input on a tty
    /// that was perfectly open. Measured 2026-08-24 on the S1 harness.
    ///
    /// The installer would have had to do this anyway: SETUP-PLAN §6.2 puts key
    /// decoding on "C# + DllImport(libc)", and a raw-mode reader that goes
    /// through a layer which also wants to configure the terminal is not raw.
    /// </summary>
    internal static int ReadByte(int fd)
    {
        byte b;
        while (true)
        {
            nint n = sys_read(fd, &b, 1);
            if (n == 1) return b;
            if (n == 0) return -1;
            // EINTR is not an error: a signal arrived while blocked in read.
            if (Marshal.GetLastPInvokeError() == 4) continue;
            return -1;
        }
    }

    /// <summary>
    /// Throw away anything already queued on `fd`.
    ///
    /// Whatever was typed before the screen appeared was not aimed at what is on
    /// it. The harness found a stray LF sitting in the queue at start-up and
    /// spent it on the first entry of the key plan, which shifted every
    /// comparison after it by one.
    /// </summary>
    internal static int Drain(int fd)
    {
        if (tcgetattr(fd, out TermiosStruct cur) != 0) return 0;
        TermiosStruct poll = cur;
        poll.c_cc[6] = 0;      // VMIN  = 0 -> return immediately
        poll.c_cc[5] = 0;      // VTIME = 0 -> without waiting
        if (tcsetattr(fd, TCSANOW, in poll) != 0) return 0;

        int dropped = 0;
        byte b;
        while (sys_read(fd, &b, 1) == 1) dropped++;

        tcsetattr(fd, TCSANOW, in cur);
        return dropped;
    }
}
