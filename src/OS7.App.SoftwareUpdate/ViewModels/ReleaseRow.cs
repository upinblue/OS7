using OS7.App.SoftwareUpdate.Model;

namespace OS7.App.SoftwareUpdate.ViewModels;

/// <summary>Why a release cannot be installed from this window, if it cannot.</summary>
public enum ReleaseBlock
{
	/// <summary>Nothing is in the way.</summary>
	None,

	/// <summary>Built for another architecture.</summary>
	ForeignArchitecture,

	/// <summary>A new major release; C12 makes this train refuse rather than attempt.</summary>
	CrossesMajor,

	/// <summary>Not newer than the release this machine runs.</summary>
	NotNewer,

	/// <summary>A hotfix for a base release this machine is not on.</summary>
	HotfixBaseMismatch,

	/// <summary>Applicable, but not signed for production.</summary>
	Development,
}

/// <summary>
/// One row of the list, and the only place in this application where a
/// judgement is made.
/// </summary>
/// <remarks>
/// <para>
/// The judgement is a PRESENTATION one: given the flags the cmdlet reports,
/// which single sentence does the operator see. It is not a policy judgement —
/// <see cref="Os7Release.Applicable"/> is read and never recomputed (G3).
/// </para>
/// <para>
/// THE ORDER OF THE REASONS IS THE DECISION. A release can be blocked several
/// ways at once and there is one line to say it in, so the order runs from the
/// fact that makes the others irrelevant to the one that is merely a caveat:
/// a release for another architecture is not this machine's business at all,
/// while a development build is one an operator may well want.
/// </para>
/// <para>
/// DEVELOPMENT IS NOT PART OF `Applicable`, and that is the subtlety this class
/// exists to get right. The cmdlet computes
/// <c>Applicable = newer AND same-major AND on-base AND not-foreign</c> —
/// provenance is not in it. `Update-OS7` then refuses a development release
/// separately, unless <c>-AllowDevelopment</c> is passed. So a release can be
/// Applicable and still not installable from here, and a window that treated
/// Applicable as "there is a button" would offer one that fails in a systemd
/// unit with the reason in a journal.
/// </para>
/// <para>
/// v1 does not offer <c>-AllowDevelopment</c> from the GUI. The switch exists,
/// in the cmdlet's own words, so that an operator says out loud that they are
/// installing something of unknown provenance; a checkbox in a window is not
/// that sentence. The row says so and names the command.
/// </para>
/// </remarks>
public sealed class ReleaseRow : ViewModelBase
{
	private bool _isSelected;

	public ReleaseRow(Os7Release release)
	{
		Release = release;
		Block = Decide(release);
	}

	public Os7Release Release { get; }

	public ReleaseBlock Block { get; }

	/// <summary>Whether this row may be ticked for installation.</summary>
	public bool IsInstallable => Block == ReleaseBlock.None;

	/// <summary>Whether the operator has ticked it.</summary>
	public bool IsSelected
	{
		get => _isSelected;
		set
		{
			// A row that cannot be installed cannot be selected, whatever the
			// view does. The view disables the checkbox as well; this is the
			// half that does not depend on a template being right.
			if (!IsInstallable)
			{
				return;
			}

			Set(ref _isSelected, value);
		}
	}

	public string Version => Release.Version;

	public string Released => Release.Released ?? string.Empty;

	public string Channel => Release.Channel ?? string.Empty;

	public string Size => FormatSize(Release.DownloadSizeBytes);

	/// <summary>The one sentence the operator reads about this row.</summary>
	public string Status => Block switch
	{
		ReleaseBlock.None =>
			Release.Hotfix
				? $"Hotfix for {Release.HotfixBase}."
				: "Available.",

		ReleaseBlock.ForeignArchitecture =>
			$"Built for {Release.Architecture}. This machine is a different architecture.",

		ReleaseBlock.CrossesMajor =>
			"A new major release. The update train does not cross one — that is an "
			+ "installation, not an update.",

		ReleaseBlock.NotNewer =>
			"Not newer than the release this machine is running.",

		ReleaseBlock.HotfixBaseMismatch =>
			$"A hotfix for {Release.HotfixBase}. Update to that release first.",

		ReleaseBlock.Development =>
			$"Not signed for production ({Release.SigningKey}). To install it anyway, run "
			+ $"sudo pwsh -c 'Update-OS7 -Version {Release.Version} -AllowDevelopment'.",

		_ => string.Empty,
	};

	/// <summary>
	/// The reason order, and the whole of this class's logic.
	/// </summary>
	private static ReleaseBlock Decide(Os7Release r)
	{
		if (r.ForeignArchitecture)
		{
			return ReleaseBlock.ForeignArchitecture;
		}

		if (r.CrossesMajor)
		{
			return ReleaseBlock.CrossesMajor;
		}

		if (!r.Newer)
		{
			return ReleaseBlock.NotNewer;
		}

		// Newer, same major, this architecture — and still not applicable. The
		// only remaining half of the cmdlet's expression is the hotfix base, so
		// that is what is in the way. Derived by ELIMINATION rather than by
		// re-testing the base version, because the machine's own version is not
		// in this object and inventing a comparison here would be the second
		// implementation G3 forbids.
		if (!r.Applicable)
		{
			return ReleaseBlock.HotfixBaseMismatch;
		}

		if (r.Development)
		{
			return ReleaseBlock.Development;
		}

		return ReleaseBlock.None;
	}

	/// <summary>
	/// Bytes as an operator reads them. MiB because that is the unit this
	/// repository states sizes in everywhere else.
	/// </summary>
	public static string FormatSize(long bytes)
	{
		if (bytes <= 0)
		{
			// The descriptor stated no component sizes. Saying "0.0 MiB" would
			// be a measurement; this is the absence of one.
			return "—";
		}

		const double Mib = 1024 * 1024;
		const double Kib = 1024;

		return bytes >= Mib
			? $"{bytes / Mib:0.0} MiB"
			: $"{bytes / Kib:0} KiB";
	}
}
