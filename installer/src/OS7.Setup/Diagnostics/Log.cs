using System.Text;

namespace OS7.Setup.Diagnostics;

internal enum Level { Info, Warn, Error }

internal readonly record struct Entry(DateTime When, Level Level, string Message,
                                     bool LiveOnly = false)
{
    /// <summary>The timestamp and level, without the message. See <see cref="Log.Transcript"/>:
    /// a redacted line has to keep its place in the sequence and lose only its text.</summary>
    public string Prefix =>
        $"{When:yyyy-MM-dd HH:mm:ss} {Level.ToString().ToUpperInvariant(),-5}";

    public override string ToString() => $"{Prefix} {Message}";
}

/// <summary>
/// Setup's log: a file, and the same lines in memory.
///
/// The memory copy is what can be shown or written WITHOUT reading the file
/// back, which matters because the interesting failures are the ones where the
/// disk the log is on is the thing that went wrong. <see cref="Recent"/> is its
/// tail for a screen; <see cref="Transcript"/> is all of it, for a file.
///
/// AND IT HAS TO OUTLIVE SETUP. `/var/log` here is casper's RAM overlay, so the
/// restart on screen 12 discards the live file entirely. `InstallLogStep` writes
/// <see cref="Transcript"/> to <see cref="Installed"/> on the target while the
/// pools are still mounted (L31).
///
/// It never throws. A logger that can fail is a second failure mode layered on
/// whatever was already going wrong, and Setup runs where there is nothing else
/// to catch it.
/// </summary>
internal static class Log
{
    public const string Directory = "/var/log/os7-setup";
    public const string Path = Directory + "/setup.log";

    /// <summary>
    /// Where the log is copied so that it OUTLIVES THE RESTART — the path as the
    /// installed machine will see it, not as Setup sees it.
    ///
    /// <see cref="Path"/> is on casper's RAM overlay. Screen 12 restarts the
    /// machine, and with it goes every step's self-proof: the hash length
    /// AccountStep read out of /etc/shadow, the initrd contents InitramfsStep
    /// listed, the unit NetworkStep read back, BootloaderStep's menu check. On a
    /// machine that boots, nobody misses them. On a machine that boots wrong,
    /// they are the record that would say why, and they are already gone.
    ///
    /// `install.log`, NOT `setup.log`, and the difference is not decoration:
    /// `os7-setup` can be run on an already-installed machine (§3 screen 1,
    /// `R=Repair`), where it will create a real <see cref="Path"/> of its own.
    /// A record OF an install and the log OF a running Setup are two different
    /// files and must not be able to land on top of one another.
    /// </summary>
    public const string Installed = "/var/log/os7-setup/install.log";

    /// <summary>
    /// Where the log was actually kept, or null if it was not kept anywhere.
    ///
    /// Screen 12 reads this instead of naming a path from a constant. An
    /// installer that prints "the log is at X" because the code says X, when the
    /// write failed, is the exact shape BUILD-NOTES keeps recording: a program
    /// reporting success for a thing that did not happen.
    /// </summary>
    public static string? Kept { get; set; }

    /// <summary>What <see cref="Recent"/> shows: the tail, for a screen.</summary>
    private const int RingSize = 200;

    /// <summary>
    /// A backstop, not a working limit. An install logs a few hundred lines
    /// (284 in a dry run, measured 2026-08-25) and this is two orders above
    /// that; it exists so that a loop nobody foresaw cannot eat a live system's
    /// RAM, and when it bites the transcript says so rather than being quietly
    /// short.
    /// </summary>
    private const int Cap = 20_000;

    /// <summary>
    /// EVERY LINE, not a ring — and the difference is the whole of L31.
    ///
    /// This was a 200-entry ring, which is right for the error screen's tail and
    /// wrong for a record that goes on a disk: a dry run logs 284 lines, so the
    /// first 84 — the whole storage phase and the start of AccountStep — fell
    /// off the front, and the copy would have arrived on the target missing
    /// exactly the proofs it exists to carry, with nothing anywhere saying so.
    /// Measured 2026-08-25, before the first VM run, by counting the lines
    /// rather than by reading the copy and finding it plausible.
    ///
    /// NOT read back from the FILE instead, although the file is complete: the
    /// marks <see cref="LiveOnly"/> puts on entries live here and not in the
    /// text, so a copy made from the file could only be redacted by pattern —
    /// the thing LiveOnly exists to avoid. And the file may never have opened.
    /// </summary>
    private static readonly List<Entry> All = new();
    private static int _dropped;
    private static readonly object Gate = new();
    private static StreamWriter? _file;
    private static bool _fileTried;

    /// <summary>The last <see cref="RingSize"/> lines, oldest first — a tail for a
    /// screen. <see cref="Transcript"/> is what wants all of them.</summary>
    public static IReadOnlyCollection<Entry> Recent
    {
        get
        {
            lock (Gate)
                return All.Count <= RingSize ? All.ToArray() : All[^RingSize..].ToArray();
        }
    }

    public static void Info(string message) => Write(Level.Info, message);
    public static void Warn(string message) => Write(Level.Warn, message);
    public static void Error(string message) => Write(Level.Error, message);

    /// <summary>
    /// A line that is true, useful, and MUST NOT OUTLIVE THE RAM DISK.
    ///
    /// Not the secret itself — nothing here ever logs one — but a line that
    /// describes one closely enough to be worth having. `passphrase set (14
    /// characters)` is the line that forced this to exist. It is exactly what
    /// you want when the passphrase typed at install does not open the disk at
    /// boot, because a trailing newline in `--passphrase-file` makes the file
    /// one byte longer than the secret and the length is where that shows. It is
    /// also, on a disk that persists, a narrowing of the search space for
    /// whoever can read /var/log — and on OS/7 the first account is in `sudo`.
    ///
    /// Both are true, so the line is kept where it is useful and dropped where
    /// it is not: in the ring and in the live file, redacted in the copy
    /// <see cref="Installed"/>.
    ///
    /// MARKED WHERE IT IS WRITTEN, never matched afterwards. A redactor that
    /// greps the transcript for "characters" has to be kept in step with every
    /// caller anyone adds later, and when it falls out of step it fails silently
    /// and in the direction that leaks.
    /// </summary>
    public static void LiveOnly(string message) => Write(Level.Info, message, liveOnly: true);

    private static void Write(Level level, string message, bool liveOnly = false)
    {
        var entry = new Entry(DateTime.Now, level, message, liveOnly);
        lock (Gate)
        {
            if (All.Count >= Cap) _dropped++;
            else All.Add(entry);
            try
            {
                File()?.WriteLine(entry.ToString());
            }
            catch
            {
                // Deliberately swallowed, and deliberately not retried: if the
                // log file has become unwritable, the ring is still intact and
                // the error screen can still show what happened.
            }
        }
    }

    /// <summary>
    /// Keep the lines in memory, NEVER OPEN THE FILE — for `--self-test`.
    ///
    /// `--self-test` runs INSIDE THE CHROOT DURING THE ISO BUILD (hook 0080), and
    /// `Main` logs one line before it dispatches. So the first thing every build
    /// did was create `/var/log/os7-setup/setup.log` in the image, and
    /// `unsquashfs` then put it on every machine Setup has ever installed: a
    /// build-time file, with build-time timestamps, sitting in the directory an
    /// operator is sent to by screen 12 — under the name the LIVE log has.
    /// Measured 2026-08-25 (3 993 bytes of self-test output). L31.
    ///
    /// It works by setting the same latch the lazy open uses, so there is no
    /// second path through <see cref="File"/> that could behave differently.
    /// </summary>
    public static void MemoryOnly()
    {
        lock (Gate) { _fileTried = true; _file = null; }
    }

    private static StreamWriter? File()
    {
        if (_fileTried) return _file;
        _fileTried = true;
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            _file = new StreamWriter(Path, append: true, Encoding.UTF8) { AutoFlush = true };
            _file.WriteLine();
            _file.WriteLine($"=== os7-setup started {DateTime.Now:yyyy-MM-dd HH:mm:ss} ===");
        }
        catch
        {
            _file = null;
        }
        return _file;
    }

    /// <summary>
    /// The whole log as text, ready to be written somewhere.
    ///
    /// Built from the RING rather than by copying the file, so it works when the
    /// file was never openable in the first place. That is not a corner case:
    /// /var not being writable is one of the things that would produce an error
    /// screen, and the error screen is one of the two callers.
    ///
    /// <paramref name="persistent"/> is the destination's LIFETIME, and it has
    /// no default on purpose. Every caller has to answer "does this outlive the
    /// restart?", because the answer decides whether the lines marked by
    /// <see cref="LiveOnly"/> go with it.
    ///
    /// A redacted line is REPLACED, not dropped. A transcript that silently
    /// omits lines is a transcript that lies about what happened; one that says
    /// "[not kept]" in the right place says both what it has and what it does
    /// not.
    /// </summary>
    public static string Transcript(bool persistent)
    {
        var sb = new StringBuilder();
        sb.Append("OS/7 Setup log — ")
          .Append(persistent ? "the installation record" : "exported")
          .Append(' ').Append($"{DateTime.Now:yyyy-MM-dd HH:mm:ss}").Append('\n');
        if (persistent)
            sb.Append("Lines shown as [not kept] were about a secret rather than "
                      + "secret themselves;\nthey exist only in the live log, which "
                      + "this machine's restart discarded.\n");
        sb.Append('\n');
        lock (Gate)
        {
            if (_dropped > 0)
                sb.Append($"{_dropped} further line(s) exceeded this log's {Cap}-line "
                          + "cap and are not here.\n");
            foreach (Entry e in All)
                sb.Append(persistent && e.LiveOnly ? $"{e.Prefix} [not kept]" : e.ToString())
                  .Append('\n');
        }
        return sb.ToString();
    }

    /// <summary>
    /// Write the log somewhere else — F2 on the error screen.
    ///
    /// See <see cref="Transcript"/> for what <paramref name="persistent"/>
    /// decides. F2's destination is `/tmp` today, which is a tmpfs and goes with
    /// the restart; when Phase 4 gives it removable media it becomes `true`, and
    /// the parameter is what will make somebody notice.
    /// </summary>
    public static bool Export(string destination, bool persistent, out string detail)
    {
        try
        {
            string? dir = System.IO.Path.GetDirectoryName(destination);
            if (!string.IsNullOrEmpty(dir)) System.IO.Directory.CreateDirectory(dir);
            using var w = new StreamWriter(destination, append: false, Encoding.UTF8);
            w.Write(Transcript(persistent).ReplaceLineEndings("\n"));
            detail = destination;
            return true;
        }
        catch (Exception ex)
        {
            detail = ex.Message;
            return false;
        }
    }

    public static void Close()
    {
        lock (Gate)
        {
            try { _file?.Flush(); _file?.Dispose(); } catch { /* see Write */ }
            _file = null;
        }
    }
}
