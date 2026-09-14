using System.Text;

namespace OS7.App.Versions.Services;

/// <summary>
/// The first part of a file, when it is the kind of file that has one.
/// </summary>
/// <remarks>
/// <para>
/// A window that lists five versions and shows none of them makes the operator
/// open each one to find the right one. Showing the text is what turns the
/// timeline from a list of timestamps into something you can read.
/// </para>
/// <para>
/// IT SNIFFS RATHER THAN TRUSTING THE EXTENSION, and BUILD-NOTES #111 is why:
/// the loader that actually opens a file decides what it is, and a name is not
/// evidence. A `.txt` holding a JPEG and a `.conf` with no extension at all are
/// both ordinary.
/// </para>
/// </remarks>
public static class TextPreview
{
	/// <summary>How much is read. Enough to fill a pane, far less than a file.</summary>
	public const int MaxBytes = 64 * 1024;

	/// <summary>
	/// Whether a byte prefix looks like text.
	/// </summary>
	/// <remarks>
	/// A NUL byte settles it — no text encoding this product meets puts one in
	/// the middle of a line, and every binary format has them early. Beyond
	/// that, a prefix that is more than a fiftieth control characters is not
	/// something to put in a pane.
	/// </remarks>
	public static bool LooksLikeText(ReadOnlySpan<byte> prefix)
	{
		if (prefix.Length == 0)
		{
			return true;
		}

		var control = 0;

		foreach (var b in prefix)
		{
			if (b == 0)
			{
				return false;
			}

			// Tab, newline, carriage return and form feed are text.
			if (b < 0x20 && b is not (0x09 or 0x0A or 0x0D or 0x0C))
			{
				control++;
			}
		}

		return control * 50 <= prefix.Length;
	}

	/// <summary>The preview, or null when the file is not text or cannot be read.</summary>
	public static string? For(string path)
	{
		try
		{
			using var stream = File.OpenRead(path);

			var buffer = new byte[Math.Min(MaxBytes, stream.Length)];
			var read = stream.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);

			var prefix = buffer.AsSpan(0, read);

			if (!LooksLikeText(prefix))
			{
				return null;
			}

			// UTF-8 with replacement rather than throwing: a file in another
			// encoding should show mostly-right text, not an error dialog.
			return Encoding.UTF8.GetString(prefix);
		}
		catch (Exception)
		{
			return null;
		}
	}
}
