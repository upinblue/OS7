using System.Runtime.InteropServices;

namespace OS7.Setup.Native;

/// <summary>
/// Raw terminal mode, and reading bytes without anything in the way.
///
/// SETUP-PLAN §6.2 puts this layer on "C# + DllImport(libc)
/// tcgetattr/tcsetattr", and §6.4 rejects Terminal.Gui partly because the layer
/// is small. Spike S1 established the shape it has to have; the two comments
/// below are the parts that are not obvious and cost a debugging cycle each.
/// </summary>
internal static unsafe partial class Termios
{
    // struct termios on glibc/Linux: four tcflag_t, cc_t c_line, cc_t c_cc[32],
    // then two speed_t. NCCS is 32 on every architecture OS/7 targets, and the
    // whole struct is 60 bytes on both.
    //
    // c_cc MUST be a fixed buffer, not a byte[] with [MarshalAs(ByValArray)]:
    // the LibraryImport source generator marshals blittable types only, and a
    // managed array inside a struct is not one. docs/BUILD-NOTES.md #22.
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

    private const int TCSANOW = 0;
    private const int VTIME = 5, VMIN = 6;
    private const int EINTR = 4;

    // Input flags, and what each one would do to a keypress if left on:
    //   ICRNL  turns the CR that Enter sends into LF
    //   IXON   eats Ctrl-S and Ctrl-Q as flow control
    //   the rest are the classic cfmakeraw set
    private const uint IGNBRK = 0x0001, BRKINT = 0x0002, PARMRK = 0x0008,
                       ISTRIP = 0x0020, INLCR = 0x0040, IGNCR = 0x0080,
                       ICRNL = 0x0100, IXON = 0x0400;
    private const uint OPOST = 0x0001;
    // ECHO off so a keypress does not paint itself over the frame; ICANON off so
    // reads return per keystroke rather than per line; ISIG off so F3=Quit is a
    // key Setup decides about rather than a signal that kills it mid-install.
    private const uint ISIG = 0x0001, ICANON = 0x0002, ECHO = 0x0008, IEXTEN = 0x8000;
    private const uint CSIZE = 0x0030, PARENB = 0x0100, CS8 = 0x0030;

    [LibraryImport("libc", SetLastError = true)]
    private static partial int tcgetattr(int fd, out TermiosStruct t);

    [LibraryImport("libc", SetLastError = true)]
    private static partial int tcsetattr(int fd, int actions, in TermiosStruct t);

    [LibraryImport("libc", SetLastError = true, EntryPoint = "read")]
    private static partial nint sys_read(int fd, byte* buf, nuint count);

    [LibraryImport("libc", SetLastError = true, EntryPoint = "isatty")]
    private static partial int sys_isatty(int fd);

    internal static bool IsTty(int fd) => sys_isatty(fd) == 1;

    /// <summary>Put `fd` into raw mode; returns the settings to restore.</summary>
    internal static TermiosStruct MakeRaw(int fd)
    {
        if (tcgetattr(fd, out TermiosStruct saved) != 0)
            throw new IOException($"tcgetattr(fd {fd}): errno {Marshal.GetLastPInvokeError()}");

        TermiosStruct raw = saved;
        raw.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
        raw.c_oflag &= ~OPOST;
        raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
        raw.c_cflag &= ~(CSIZE | PARENB);
        raw.c_cflag |= CS8;
        raw.c_cc[VMIN] = 1;     // block until at least one byte
        raw.c_cc[VTIME] = 0;    // and never time out on a partial sequence

        if (tcsetattr(fd, TCSANOW, in raw) != 0)
            throw new IOException($"tcsetattr(fd {fd}): errno {Marshal.GetLastPInvokeError()}");
        return saved;
    }

    internal static void Restore(int fd, TermiosStruct saved) => tcsetattr(fd, TCSANOW, in saved);


    /// <summary>
    /// One byte, or -1 for "nothing" (end of input, or the VTIME poll expiring).
    ///
    /// read(2) directly, and NOT Console.OpenStandardInput(). .NET's console
    /// stream applies termios settings of its own, and with it in the path a
    /// raw-mode reader returned exactly one byte and then reported end of input
    /// on a tty that was open and had keys arriving. Measured by spike S1;
    /// docs/BUILD-NOTES.md #29.
    /// </summary>
    internal static int ReadByte(int fd)
    {
        byte b;
        while (true)
        {
            nint n = sys_read(fd, &b, 1);
            if (n == 1) return b;
            if (n == 0) return -1;
            if (Marshal.GetLastPInvokeError() == EINTR) continue;  // a signal, not an error
            return -1;
        }
    }

    /// <summary>
    /// Discard anything already queued, and say how much there was.
    ///
    /// Whatever was typed before the screen appeared was not aimed at what is on
    /// it — and on an installer that is not a cosmetic problem, because the
    /// first screen has a key that starts an install. S1 found a stray LF in the
    /// queue at start-up spending itself on the first expected keypress.
    /// </summary>
    internal static int Drain(int fd)
    {
        if (tcgetattr(fd, out TermiosStruct cur) != 0) return 0;
        TermiosStruct poll = cur;
        poll.c_cc[VMIN] = 0;
        poll.c_cc[VTIME] = 0;
        if (tcsetattr(fd, TCSANOW, in poll) != 0) return 0;

        int dropped = 0;
        byte b;
        while (sys_read(fd, &b, 1) == 1) dropped++;

        tcsetattr(fd, TCSANOW, in cur);
        return dropped;
    }
}
