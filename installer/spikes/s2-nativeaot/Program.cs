// OS/7 — Phase 0 spike S2: does NativeAOT actually work for what os7-setup needs?
//
// SETUP-PLAN §10 S2 asks for "two static binaries that run in the ISO". L11 is
// the doubt behind it: NativeAOT restores Microsoft.DotNet.ILCompiler from
// NuGet at publish time and has never been tried against Canonical's packaged
// dotnet-sdk-10.0.
//
// Every check below maps to something §6.2 commits os7-setup to doing:
//
//   P/Invoke into libc      raw terminal mode (tcgetattr/tcsetattr), TIOCGWINSZ,
//                           and one write(2) per frame
//   source-generated JSON   the InstallPlan model, explicitly "AOT-safe"
//   Process.Start           sgdisk, zpool, unsquashfs, grub-install, pwsh
//   globalization           English + German (L9)
//
// Reflection-based JSON and Microsoft.PowerShell.SDK are the two things §6.3
// rules out precisely because NativeAOT cannot take them; nothing here uses them.

using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OS7.Spike;

internal sealed record Disk(string Path, long Bytes, bool Removable);
internal sealed record Plan(string Release, string BootEnvironment, Disk Target);

// Source-generated, so no reflection and nothing for the trimmer to guess at.
[JsonSourceGenerationOptions(WriteIndented = false)]
[JsonSerializable(typeof(Plan))]
internal sealed partial class PlanContext : JsonSerializerContext;

internal static partial class Libc
{
    // asm-generic, so the same value on x86_64 and aarch64.
    internal const ulong TIOCGWINSZ = 0x5413;

    [StructLayout(LayoutKind.Sequential)]
    internal struct WinSize
    {
        public ushort Rows, Cols, XPixel, YPixel;
    }

    // struct termios is identical on both target arches: four 4-byte flag
    // words, c_line, NCCS=32 control chars, then two 4-byte speeds (60 bytes).
    //
    // c_cc is a `fixed` buffer, NOT a byte[] with [MarshalAs(ByValArray)]. The
    // LibraryImport source generator only handles blittable types and rejects
    // the managed-array form outright:
    //
    //   SYSLIB1051: The type 'Termios' is not supported by source-generated
    //   P/Invokes.
    //
    // os7-setup's Native/Termios.cs has to be written this way too (§6.2).
    [StructLayout(LayoutKind.Sequential)]
    internal unsafe struct Termios
    {
        public uint IFlag, OFlag, CFlag, LFlag;
        public byte Line;
        public fixed byte Cc[32];
        public uint ISpeed, OSpeed;
    }

    [LibraryImport("libc", SetLastError = true)]
    internal static partial int getpid();

    [LibraryImport("libc", SetLastError = true)]
    internal static partial nint write(int fd, byte[] buf, nint count);

    [LibraryImport("libc", SetLastError = true)]
    internal static partial int isatty(int fd);

    [LibraryImport("libc", SetLastError = true)]
    internal static partial int ioctl(int fd, ulong request, ref WinSize ws);

    [LibraryImport("libc", SetLastError = true)]
    internal static partial int tcgetattr(int fd, out Termios t);

    [LibraryImport("libc", SetLastError = true)]
    internal static partial int tcsetattr(int fd, int actions, ref Termios t);
}

internal static class Program
{
    private static int _faults;

    private static void Ok(string what, string detail = "")
        => Console.WriteLine($"    ok       {what}{(detail.Length > 0 ? "  — " + detail : "")}");

    private static void Info(string what, string detail)
        => Console.WriteLine($"    note     {what}  — {detail}");

    private static void Fail(string what, string why)
    {
        Console.WriteLine($"    FAILED   {what}  — {why}");
        _faults++;
    }

    private static int Main(string[] args)
    {
        Console.WriteLine("=== S2 os7-s2: NativeAOT smoke test ===");
        Console.WriteLine($"    arch     {RuntimeInformation.OSArchitecture}  " +
                          $"({RuntimeInformation.RuntimeIdentifier})");
        Console.WriteLine($"    runtime  {RuntimeInformation.FrameworkDescription}");

        // 1. The binary must genuinely be native, not a framework-dependent
        //    launcher that happens to work because a runtime is installed.
        //    Under NativeAOT this is false; on CoreCLR it is true.
        if (RuntimeFeature.IsDynamicCodeSupported)
            Fail("native AOT", "dynamic code is supported — this is NOT an AOT build");
        else
            Ok("native AOT", "no dynamic code support, as expected");

        // 2. P/Invoke — the whole TUI layer rests on it.
        try
        {
            int pid = Libc.getpid();
            if (pid <= 0) Fail("P/Invoke getpid", $"returned {pid}");
            else Ok("P/Invoke getpid", $"pid {pid}");

            // Real bytes, not an empty string: write(fd, buf, 0) returns 0
            // and would satisfy `n == probe.Length` while proving nothing.
            // Setup flushes one frame per repaint through exactly this call.
            byte[] probe = Encoding.UTF8.GetBytes("    ....     write(2) probe — this line came from libc\n");
            nint n = Libc.write(1, probe, probe.Length);
            if (n != probe.Length) Fail("P/Invoke write(2)", $"wrote {n} of {probe.Length}");
            else Ok("P/Invoke write(2)", $"{n} bytes straight to fd 1");
        }
        catch (Exception e) { Fail("P/Invoke", e.Message); }

        // 3. Terminal control. Informational, because a container or a pipe is
        //    legitimately not a tty — what must not happen is a crash or a
        //    missing entry point.
        try
        {
            bool tty = Libc.isatty(0) == 1;
            if (tty)
            {
                var ws = default(Libc.WinSize);
                if (Libc.ioctl(1, Libc.TIOCGWINSZ, ref ws) == 0)
                    Ok("ioctl TIOCGWINSZ", $"{ws.Cols}x{ws.Rows}");
                else
                    Info("ioctl TIOCGWINSZ", "failed on a tty");

                if (Libc.tcgetattr(0, out var t) == 0)
                {
                    uint before = t.LFlag;
                    if (Libc.tcsetattr(0, 0, ref t) == 0)
                        Ok("tcgetattr/tcsetattr", $"lflag 0x{before:x} round-tripped");
                    else
                        Fail("tcsetattr", "returned non-zero on a tty");
                }
                else Fail("tcgetattr", "returned non-zero on a tty");
            }
            else
            {
                Info("terminal control", "stdin is not a tty here; entry points resolved");
                _ = Libc.tcgetattr(0, out _);   // resolve the symbol regardless
            }
        }
        catch (Exception e) { Fail("terminal control", e.Message); }

        // 4. Source-generated JSON — the InstallPlan model.
        try
        {
            var plan = new Plan("2026.08.1", "os7_2026.08.1_202608230935",
                                new Disk("/dev/vda", 42949672960L, false));
            string json = JsonSerializer.Serialize(plan, PlanContext.Default.Plan);
            var back = JsonSerializer.Deserialize(json, PlanContext.Default.Plan);
            if (back is null || back != plan) Fail("System.Text.Json (source-gen)", "round-trip mismatch");
            else Ok("System.Text.Json (source-gen)", json);
        }
        catch (Exception e) { Fail("System.Text.Json (source-gen)", e.Message); }

        // 5. Shelling out — most of the install actually happens this way.
        try
        {
            var psi = new ProcessStartInfo("/bin/uname", "-m")
            { RedirectStandardOutput = true };
            using var p = Process.Start(psi)!;
            string uname = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit();
            if (p.ExitCode != 0 || uname.Length == 0) Fail("Process.Start", $"exit {p.ExitCode}");
            else Ok("Process.Start", $"/bin/uname -m -> {uname}");
        }
        catch (Exception e) { Fail("Process.Start", e.Message); }

        // 6. Globalization. Not fatal — but if ICU did not resolve, every
        //    German string in Setup silently becomes invariant, and that is
        //    worth knowing here rather than after translation work.
        try
        {
            var de = CultureInfo.GetCultureInfo("de-DE");
            if (de.EnglishName.Contains("Invariant", StringComparison.Ordinal))
                Info("globalization", "ICU did NOT load — cultures are invariant");
            else
                Ok("globalization", $"de-DE -> {de.EnglishName}, {de.NativeName}");
        }
        catch (Exception e) { Info("globalization", $"unavailable: {e.Message}"); }

        Console.WriteLine(_faults == 0
            ? "S2-BINARY: OK"
            : $"S2-BINARY: FAILED ({_faults} check(s))");
        return _faults == 0 ? 0 : 1;
    }
}
