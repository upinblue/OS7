namespace OS7.App.Versions.Services;

/// <summary>One mounted filesystem, as the kernel describes it.</summary>
/// <param name="MountPoint">Where it is mounted, e.g. <c>/home/os7admin</c>.</param>
/// <param name="FsType">e.g. <c>zfs</c>, <c>ext4</c>, <c>tmpfs</c>.</param>
/// <param name="Source">The device or dataset, e.g. <c>rpool/USERDATA/os7admin_af456a8e</c>.</param>
public sealed record Mount(string MountPoint, string FsType, string Source)
{
	public bool IsZfs => string.Equals(FsType, "zfs", StringComparison.Ordinal);
}

/// <summary>
/// Which filesystem a path is on, and which ZFS dataset that is — from the
/// kernel, with no <c>zfs</c> command.
/// </summary>
/// <remarks>
/// <para>
/// Measured (VERSIONS-PLAN M-V10): <c>/proc/self/mountinfo</c> carries
/// <c>/home/os7admin … zfs rpool/USERDATA/os7admin_af456a8e</c>, so resolving a
/// path to its dataset is a longest-prefix match over a file the kernel writes.
/// That keeps the hot path — which runs for every path the file manager hands
/// over — free of a process launch.
/// </para>
/// <para>
/// NOT /etc/mtab AND NOT `df`. mountinfo is the kernel's own view, is always
/// current, and is the only one of the three that states the filesystem type
/// and the source in fields whose positions are defined rather than formatted.
/// </para>
/// </remarks>
public static class MountTable
{
	public const string ProcMountInfo = "/proc/self/mountinfo";

	/// <summary>Read the mount table. Empty on any failure — never throws.</summary>
	public static IReadOnlyList<Mount> Read(string path = ProcMountInfo)
	{
		try
		{
			return Parse(File.ReadAllLines(path));
		}
		catch (Exception)
		{
			// A machine with no /proc, or no permission, has no version history
			// to offer either. The window says "no history here" (V6) rather
			// than failing, which is a better answer than a stack trace.
			return Array.Empty<Mount>();
		}
	}

	/// <summary>
	/// Parse mountinfo lines.
	/// </summary>
	/// <remarks>
	/// The format is:
	/// <code>
	/// 36 25 0:31 / /home/os7admin rw,relatime shared:1 - zfs rpool/USERDATA/x rw,xattr
	/// |                 |                             |   |   |
	/// fields[4]         mountpoint                    separator, then fstype, source
	/// </code>
	/// THE SEPARATOR IS WHY THIS IS PARSED AND NOT SPLIT. Between the mount
	/// point and the `-` there is a VARIABLE number of optional fields
	/// (`shared:1`, `master:2`, and whatever a future kernel adds), so counting
	/// from the left past field 5 is wrong and counting from the right is
	/// wrong. Everything before the lone `-` is one part, everything after is
	/// the other.
	/// </remarks>
	public static IReadOnlyList<Mount> Parse(IEnumerable<string> lines)
	{
		var mounts = new List<Mount>();

		foreach (var line in lines)
		{
			var separator = line.IndexOf(" - ", StringComparison.Ordinal);
			if (separator < 0)
			{
				continue;
			}

			var left = line[..separator].Split(' ', StringSplitOptions.RemoveEmptyEntries);
			var right = line[(separator + 3)..]
				.Split(' ', StringSplitOptions.RemoveEmptyEntries);

			if (left.Length < 5 || right.Length < 2)
			{
				continue;
			}

			mounts.Add(new Mount(Unescape(left[4]), right[0], Unescape(right[1])));
		}

		return mounts;
	}

	/// <summary>
	/// The mount a path sits on: the longest mount point that is a prefix of it.
	/// </summary>
	/// <remarks>
	/// Longest wins, and that is the whole of it. `/home/os7admin/notes.txt` is
	/// under both `/` and `/home/os7admin`, and only the second one has the
	/// snapshots. Sorting shortest-first and taking the last match would work
	/// too; this states the intent.
	/// </remarks>
	public static Mount? For(string path, IReadOnlyList<Mount> mounts)
	{
		var full = Normalise(path);
		Mount? best = null;

		foreach (var mount in mounts)
		{
			if (!IsUnder(full, mount.MountPoint))
			{
				continue;
			}

			if (best is null || mount.MountPoint.Length > best.MountPoint.Length)
			{
				best = mount;
			}
		}

		return best;
	}

	/// <summary>Whether <paramref name="path"/> is at or below <paramref name="root"/>.</summary>
	/// <remarks>
	/// A STRING PREFIX IS NOT ENOUGH: `/home/os7admin2` starts with
	/// `/home/os7admin` and is a different user's home. The next character has
	/// to be a separator, or the two have to be equal.
	/// </remarks>
	public static bool IsUnder(string path, string root)
	{
		if (root == "/")
		{
			return path.StartsWith('/');
		}

		if (!path.StartsWith(root, StringComparison.Ordinal))
		{
			return false;
		}

		return path.Length == root.Length || path[root.Length] == '/';
	}

	/// <summary>The part of <paramref name="path"/> below <paramref name="root"/>.</summary>
	public static string RelativeTo(string path, string root)
	{
		var full = Normalise(path);
		if (!IsUnder(full, root))
		{
			throw new ArgumentException($"'{full}' is not under '{root}'.", nameof(path));
		}

		var rest = root == "/" ? full[1..] : full[root.Length..];
		return rest.TrimStart('/');
	}

	/// <summary>
	/// A trailing slash on a directory would make every comparison below it
	/// off by one, so it goes. The root keeps its own.
	/// </summary>
	public static string Normalise(string path)
	{
		if (string.IsNullOrEmpty(path))
		{
			return "/";
		}

		var trimmed = path.TrimEnd('/');
		return trimmed.Length == 0 ? "/" : trimmed;
	}

	/// <summary>
	/// mountinfo octal-escapes space, tab, newline and backslash. A path with a
	/// space in it is ordinary in a home directory, and an unescaped one would
	/// silently resolve to the wrong mount.
	/// </summary>
	public static string Unescape(string value)
	{
		if (!value.Contains('\\', StringComparison.Ordinal))
		{
			return value;
		}

		var result = new System.Text.StringBuilder(value.Length);

		for (var i = 0; i < value.Length; i++)
		{
			if (value[i] == '\\' && i + 3 < value.Length
				&& IsOctal(value[i + 1]) && IsOctal(value[i + 2]) && IsOctal(value[i + 3]))
			{
				result.Append((char)Convert.ToInt32(value.Substring(i + 1, 3), 8));
				i += 3;
				continue;
			}

			result.Append(value[i]);
		}

		return result.ToString();
	}

	private static bool IsOctal(char c) => c is >= '0' and <= '7';
}
