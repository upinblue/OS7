using System.Text.Json.Serialization;

namespace OS7.App.SoftwareUpdate.Model;

/// <summary>
/// One release, exactly as <c>Get-OS7Release -Available</c> emits it.
/// </summary>
/// <remarks>
/// <para>
/// This mirrors the <c>OS7.Release</c> object built in
/// <c>powershell/OS7/OS7.Update.ps1</c> property for property. It is a
/// TRANSCRIPT, not a design: docs/GUI-APPS-PLAN.md G3 says this application
/// decides nothing the cmdlet has not already decided, and the way that rule
/// gets broken in practice is a field being "simplified" on the way in.
/// </para>
/// <para>
/// <see cref="Applicable"/> in particular is READ, never derived. The cmdlet
/// reports it alongside four separate reasons because, in its own words,
/// "'not applicable' for four different reasons is four different conversations
/// with the operator". Recomputing it here from <see cref="Newer"/> and the
/// rest would be a second implementation of C12's refusal rule, which is
/// BUILD-NOTES #66's shape.
/// </para>
/// </remarks>
public sealed class Os7Release
{
	public string Version { get; init; } = string.Empty;

	public string? Channel { get; init; }

	/// <summary>When it was built. A string, because the cmdlet emits one.</summary>
	public string? Released { get; init; }

	public string? Architecture { get; init; }

	public string? Suite { get; init; }

	/// <summary>The Ubuntu archive snapshot this release is pinned to.</summary>
	public string? Snapshot { get; init; }

	/// <summary>Whether <c>Update-OS7</c> would take it. The cmdlet's answer.</summary>
	public bool Applicable { get; init; }

	public bool Newer { get; init; }

	public bool CrossesMajor { get; init; }

	public bool ForeignArchitecture { get; init; }

	public bool Hotfix { get; init; }

	/// <summary>The release a hotfix overlays, or null.</summary>
	public string? HotfixBase { get; init; }

	/// <summary>
	/// True when the descriptor carries no <c>signing</c> block at all, as well
	/// as when it declares one marked development. The cmdlet folds both into
	/// this single answer on purpose — "unknown provenance is not provenance" —
	/// so the application must not try to tell them apart.
	/// </summary>
	public bool Development { get; init; }

	public string? SigningKey { get; init; }

	public IReadOnlyList<string> Migrations { get; init; } = Array.Empty<string>();

	public Os7ReleaseDescriptor? Descriptor { get; init; }

	/// <summary>
	/// What the release weighs, summed from the sizes its own descriptor
	/// states for its components.
	/// </summary>
	/// <remarks>
	/// This is arithmetic over a stated field, not a judgement — but it IS a
	/// number this application produces and no cmdlet does, which is the seam
	/// G3 warns about. If "download size" ever stops meaning "all components"
	/// (only the changed ones, say), this is where it would be wrong alone. A
	/// <c>DownloadSize</c> property on <c>OS7.Release</c> is the better home
	/// and is owed; until then the definition lives here, in one expression,
	/// with the self-test covering it.
	/// </remarks>
	[JsonIgnore]
	public long DownloadSizeBytes =>
		Descriptor?.Components?.Sum(c => c.Size) ?? 0;
}

/// <summary>The release descriptor, of which this application reads one part.</summary>
public sealed class Os7ReleaseDescriptor
{
	[JsonPropertyName("components")]
	public IReadOnlyList<Os7Component>? Components { get; init; }
}

/// <summary>One package in a release.</summary>
public sealed class Os7Component
{
	[JsonPropertyName("package")]
	public string? Package { get; init; }

	[JsonPropertyName("size")]
	public long Size { get; init; }
}
