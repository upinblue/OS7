using System.Text.Json.Serialization;

namespace OS7.App.Versions.Model;

/// <summary>
/// One snapshot, as the Zfs module reports it.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="Creation"/> COMES FROM ZFS AND NOWHERE ELSE (VERSIONS-PLAN V2).
/// The obvious shortcut — <c>stat</c> on the snapshot's directory under
/// <c>.zfs/snapshot/</c> — reports the dataset root's mtime *inside* that
/// snapshot, which is a real value about something else: measured on a machine,
/// four snapshots taken minutes and days apart all claimed the same instant
/// (M-V11). A timeline built on that would be silently wrong at every point.
/// </para>
/// <para>
/// It arrives as ISO 8601 with an offset, because `ConvertTo-Json` serialises a
/// `[datetime]` that way — which is why this application does not repeat
/// Software Update's culture-formatting repair. The JSON path is the one that
/// does not lose the information.
/// </para>
/// </remarks>
public sealed class SnapshotRef
{
	/// <summary>The full ZFS name, <c>pool/dataset@snapshot</c>.</summary>
	public string Name { get; init; } = string.Empty;

	public DateTimeOffset Creation { get; init; }

	/// <summary>Bytes held only by this snapshot.</summary>
	public long Used { get; init; }

	/// <summary>Bytes the dataset referenced at this point.</summary>
	public long Referenced { get; init; }

	/// <summary>The part after the <c>@</c> — what the directory is called.</summary>
	[JsonIgnore]
	public string ShortName
	{
		get
		{
			var at = Name.IndexOf('@');
			return at < 0 ? Name : Name[(at + 1)..];
		}
	}

	/// <summary>The dataset this is a snapshot of.</summary>
	[JsonIgnore]
	public string Dataset
	{
		get
		{
			var at = Name.IndexOf('@');
			return at < 0 ? Name : Name[..at];
		}
	}

	/// <summary>
	/// The retention bucket sanoid put it in, if it is sanoid's.
	/// </summary>
	/// <remarks>
	/// Read from the name because that is where sanoid puts it
	/// (<c>autosnap_2026-09-14_18:00:02_hourly</c>), and it is used ONLY to
	/// draw the timeline's tick density — never to decide anything. A snapshot
	/// an administrator took by hand has no bucket and is shown just the same,
	/// which is the case name-parsing would otherwise lose.
	/// </remarks>
	[JsonIgnore]
	public string? Bucket
	{
		get
		{
			foreach (var bucket in new[] { "frequently", "hourly", "daily", "weekly", "monthly", "yearly" })
			{
				if (ShortName.EndsWith('_' + bucket, StringComparison.Ordinal))
				{
					return bucket;
				}
			}

			return null;
		}
	}
}
