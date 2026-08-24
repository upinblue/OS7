using System.Runtime.Versioning;

// os7-setup runs on Linux and nowhere else, and says so rather than being
// guarded per call site.
//
// Without this the platform-compatibility analyser refuses PosixSignal.SIGWINCH
// as "unsupported on: windows" — which is true and irrelevant. Declaring the
// platform is the honest fix; suppressing CA1416 would also silence it for a
// call that genuinely is not available on the target.
//
// It is not merely a Linux-only program either: it reads /proc/cmdline,
// /sys/class/graphics, /usr/share/i18n and /usr/share/X11, drives the Linux VT's
// palette, and installs an operating system onto ZFS. There is no port here to
// keep open.
[assembly: SupportedOSPlatform("linux")]
