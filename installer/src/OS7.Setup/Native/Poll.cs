using System.Runtime.InteropServices;

namespace OS7.Setup.Native;

internal enum Waited { Ready, Timeout, HangUp, Error }

/// <summary>
/// Wait for input WITH a deadline — the thing a blocking read cannot do.
///
/// Two problems, one answer.
///
/// THE CONSOLE CHANGES UNDERNEATH SETUP. fbcon takes the console over some
/// seconds into the boot, replacing the dummy device Setup started on and
/// clearing everything on it (see Terminal.Retake). A reader blocked in read(2)
/// does not come back until somebody presses a key, so the screen would sit
/// blank until the user poked it. .NET installs its signal handlers with
/// SA_RESTART, so SIGWINCH does not break the read either. An idle tick does.
///
/// THE BARE ESCAPE KEY. A lone ESC is the prefix of every sequence in the key
/// table, so a blocking reader waits on it forever. The classic answer is a
/// short timer after ESC, and this is that timer.
///
/// poll(2) rather than VMIN/VTIME because it separates "nothing arrived" from
/// "the terminal went away": with VTIME both are read() returning 0, and an
/// installer that cannot tell an idle user from a hangup will either spin or
/// quit on somebody thinking.
/// </summary>
internal static partial class Poll
{
    private const short POLLIN = 0x001, POLLERR = 0x008, POLLHUP = 0x010, POLLNVAL = 0x020;
    private const int EINTR = 4;

    [StructLayout(LayoutKind.Sequential)]
    private struct PollFd
    {
        public int fd;
        public short events;
        public short revents;
    }

    [LibraryImport("libc", SetLastError = true, EntryPoint = "poll")]
    private static partial int sys_poll(ref PollFd fds, nuint nfds, int timeoutMs);

    internal static Waited Wait(int fd, int timeoutMs)
    {
        var p = new PollFd { fd = fd, events = POLLIN, revents = 0 };
        while (true)
        {
            int n = sys_poll(ref p, 1, timeoutMs);
            if (n < 0)
            {
                // A signal arrived. Returning Timeout rather than retrying is
                // deliberate: the caller re-checks its state on every tick, and
                // a signal is exactly the moment when that is worth doing.
                if (Marshal.GetLastPInvokeError() == EINTR) return Waited.Timeout;
                return Waited.Error;
            }
            if (n == 0) return Waited.Timeout;
            if ((p.revents & (POLLHUP | POLLNVAL)) != 0) return Waited.HangUp;
            if ((p.revents & POLLERR) != 0) return Waited.Error;
            return Waited.Ready;
        }
    }
}
