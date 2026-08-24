using System.Text;

namespace OS7.Setup.Diagnostics;

internal enum Level { Info, Warn, Error }

internal readonly record struct Entry(DateTime When, Level Level, string Message)
{
    public override string ToString() =>
        $"{When:yyyy-MM-dd HH:mm:ss} {Level.ToString().ToUpperInvariant(),-5} {Message}";
}

/// <summary>
/// Setup's log: a file, and a ring in memory.
///
/// The file is what §3.1's error screen offers to write to removable media. The
/// ring is what the error screen can show WITHOUT reading the file back, which
/// matters because the interesting failures are the ones where the disk the log
/// is on is the thing that went wrong.
///
/// It never throws. A logger that can fail is a second failure mode layered on
/// whatever was already going wrong, and Setup runs where there is nothing else
/// to catch it.
/// </summary>
internal static class Log
{
    public const string Directory = "/var/log/os7-setup";
    public const string Path = Directory + "/setup.log";

    private const int RingSize = 200;
    private static readonly Queue<Entry> Ring = new(RingSize);
    private static readonly object Gate = new();
    private static StreamWriter? _file;
    private static bool _fileTried;

    /// <summary>Everything still in memory, oldest first.</summary>
    public static IReadOnlyCollection<Entry> Recent
    {
        get { lock (Gate) return Ring.ToArray(); }
    }

    public static void Info(string message) => Write(Level.Info, message);
    public static void Warn(string message) => Write(Level.Warn, message);
    public static void Error(string message) => Write(Level.Error, message);

    private static void Write(Level level, string message)
    {
        var entry = new Entry(DateTime.Now, level, message);
        lock (Gate)
        {
            if (Ring.Count >= RingSize) Ring.Dequeue();
            Ring.Enqueue(entry);
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
    /// Copy the log somewhere else — F2 on the error screen.
    ///
    /// Written from the RING rather than by copying the file, so it works when
    /// the file was never openable in the first place. That is not a corner
    /// case: /var not being writable is one of the things that would produce an
    /// error screen.
    /// </summary>
    public static bool Export(string destination, out string detail)
    {
        try
        {
            string? dir = System.IO.Path.GetDirectoryName(destination);
            if (!string.IsNullOrEmpty(dir)) System.IO.Directory.CreateDirectory(dir);
            using var w = new StreamWriter(destination, append: false, Encoding.UTF8);
            w.WriteLine($"OS/7 Setup log — exported {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
            w.WriteLine();
            foreach (Entry e in Recent) w.WriteLine(e.ToString());
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
