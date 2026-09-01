# =============================================================================
# OS/7 — the update train.
#
# docs/RELEASE-AND-UPDATE-PLAN.md §4.2, as corrected by
# docs/CURATION-AND-DELIVERY-PLAN.md §9 (C10). Dot-sourced by OS7.psm1.
#
# WHAT THIS FILE IS. Until 2026-08-26 `Update-OS7` was a stub, and its help said
# why: "there is nothing yet to point them AT". C7 built the thing to point at —
# nine OS/7 packages in a signed suite, with a release descriptor and a signed
# index. This is the other half.
#
# THE SEQUENCE, in the order it runs. Steps are numbered as §4.2 numbers them so
# that a reader can hold the plan beside the code; 0 is this file's own and is
# argued for where it appears.
#
#   0.  preflight: read the machine, fetch and VERIFY the index and the target
#       descriptor, and refuse — wrong Major (C12), stale index, bad signature,
#       a development key without -AllowDevelopment, a drifted machine
#   1.  snapshot rpool/ROOT/<cur>, bpool/BOOT/<cur> AND rpool/DATA
#   2.  clone the pair into rpool/ROOT/<new> + bpool/BOOT/<new>
#   3.  ASSEMBLE the clone: the in-BE datasets, the bpool half, the out-of-BE
#       rpool/DATA mounts, then /dev /proc /sys /run
#   4.  point apt at BOTH repositories — the pinned snapshot and the OS/7 suite
#   5.  apt install os7-<mode>=<version>, then full-upgrade, then autoremove
#   6.  DELETED by C10 — os7-release owns /etc/os-release. But only on a machine
#       that HOLDS os7-release, which today's ISO does not install, so this file
#       asks the machine which world it is in rather than assuming.
#   6'. run the release's migrations, in order, keyed by the version being
#       upgraded FROM
#   7.  update-initramfs
#   8.  update-grub inside the clone
#   9.  activate the pair, then prune to -Keep environments
#   10. reboot — only with -Reboot, and never silently
#
# THE THREE THINGS THIS FILE IS MOST LIKELY TO GET WRONG, and what stops each:
#
#   * A CLONE THAT IS ONLY PARTLY ASSEMBLED LOOKS FINE. Every dataset in a new
#     boot environment is `canmount=noauto` (OS7.psm1's New-OS7BootEnvironment),
#     so nothing mounts itself and a missing mount is silent. If apt then runs
#     against a /var with holes, dpkg writes into the clone's ROOT dataset where
#     /var/log and the agent state should have been — and the damage is
#     invisible until the rollback that was supposed to preserve them.
#     Assert-OS7UpdateRootAssembled asks the kernel, through /proc/self/mountinfo,
#     and refuses to chroot until every expected path is a real mount.
#
#   * MOUNTING THE CLONE MAKES TWO ENVIRONMENTS REPORT `Active`.
#     Get-OS7BootEnvironment sets Active from ZFS's `mounted` property, which is
#     "mounted anywhere" and not "mounted at /". So while this file has the
#     clone assembled, the BE cmdlets must not be called: New-OS7BootEnvironment
#     resolves its default -From from `Where-Object Active`, and two matches
#     coerce to the string "os7_a os7_b". BUILD-NOTES #65's shape. Everything
#     here dismounts before it touches a BE cmdlet, and says so at each site.
#
#   * apt's EXIT CODE IS NOT THE ANSWER. `apt-get update` exits 0 with every
#     index failed; `apt-get install` exits 0 having installed a version other
#     than the one asked for when a pin intervenes. Every apt step here is
#     followed by a question put to dpkg or apt-cache about the state that was
#     supposed to change. The standing rule in docs/BUILD-NOTES.md.
# =============================================================================

# /run is a tmpfs, so neither the lock nor the assembly point outlives a boot —
# which is what you want of both: a machine that was reset mid-update comes up
# with nothing half-mounted and nothing holding a lock nobody owns.
$script:OS7UpdateLock  = '/run/os7-update.lock'
$script:OS7UpdateRoot  = '/run/os7-update'

# The trust anchor os7-release ships (CURATION-AND-DELIVERY-PLAN §6.3), and the
# apt source it owns.
$script:OS7Keyring   = '/usr/share/keyrings/os7-archive-keyring.gpg'
$script:OS7AptSource = '/etc/apt/sources.list.d/os7.sources'

# THE PIN, AND WHY THIS FILE READS IT RATHER THAN release.json.
#
# There are three files called release.json in this repository and they have
# three different shapes: hook 0075 writes a MEASURED one into every image
# (components, packages_manifest — and no os7_suite); the os7-release package
# ships an AUTHORED one (os7_suite, metapackage — and no packages_manifest); and
# the repository holds the DESCRIPTOR (components as an array). The seam is
# named in build/lib/build-os7-packages.sh and is not resolved.
#
# release.conf is the one file that is the same on every machine: build.sh
# stages it into /usr/lib/os7/ for the ISO, and os7-release ships the identical
# file. So the suite, the archive base and the repository URI are read from
# there, and release.json is used only for what every shape of it carries — the
# version. A cmdlet that read its suite from release.json would work on some
# machines and return $null on others, which is worse than not reading it.
$script:OS7ReleaseConf = '/usr/lib/os7/release.conf'

# WHERE THE CHOSEN CHANNEL LIVES.
#
# Not in the apt source: a deb822 source has no field for it, and the
# SUITE is per-Major (os7-1.0) rather than per-channel, so it cannot carry
# it either. Not in release.conf: that file is shipped by os7-release and
# a package upgrade would put the shipped value back.
#
# /etc, because it is a decision an operator made about THIS machine, and
# because /etc is inside the boot environment — so a rollback returns the
# machine to the channel it was on, which is the same answer a rollback
# gives to every other question.
$script:OS7UpdateConf = '/etc/os7/update.conf'

# Migrations (C10 step 6'). The scripts ship in os7-release; the record of what
# has run lives beside them INSIDE the boot environment.
#
# INSIDE, and that is not an oversight. /var/lib/os7 is not a dataset of its
# own, so it lands in the environment's root dataset — which means a rollback
# takes the record with it. That is exactly right, and C10 says so from the
# other end: migrations "must be idempotent because a rollback followed by a
# re-update runs them twice". They run twice BECAUSE the record rolls back. If
# the record lived outside the environment, a rollback would leave a machine
# claiming to have run migrations that had been rolled away.
$script:OS7MigrationDir   = '/usr/lib/os7/migrations'
$script:OS7MigrationState = '/var/lib/os7/migrations'

# The log lives on rpool/DATA/log, which is OUTSIDE the boot environment
# (RELEASE-AND-UPDATE-PLAN §4.4: "The log explaining why an update failed must
# not vanish with the update"). That is the whole reason /var/log is out, and
# this is the first cmdlet for which it matters.
$script:OS7UpdateLog = '/var/log/os7/update.log'

# How many boot environments survive an update, counting the new one.
#
# UL9: "Boot environments accumulate and fill the pool" — mitigated by "a
# retention policy shipped by default, not left to the operator". Two: the one
# just built and the one it replaced, so Restore-OS7 always has a target and the
# pool does not grow without bound. -Keep overrides it.
$script:OS7KeepBootEnvironments = 2


# ---------------------------------------------------------------------------
# The pin, the source, and fetching from it
# ---------------------------------------------------------------------------

function Write-OS7UpdateLog {
	<#
	.SYNOPSIS
		Append one line to the update log. Internal.

	.DESCRIPTION
		§6: "On a managed fleet nobody types Update-OS7. It has to run from a
		systemd timer, from Intune, and from Azure Arc — non-interactive,
		exit-code-correct, and logging somewhere both platforms can read."

		A PowerShell host's transcript is not somewhere both platforms can read.
		A file is.

		IT IS ON rpool/DATA/log, OUTSIDE THE BOOT ENVIRONMENT, and that is the
		whole reason §4.4 puts /var/log out: "The log explaining why an update
		failed must not vanish with the update." This is the first cmdlet for
		which that sentence has a subject. A log written inside the environment
		would be rolled back by the recovery from the failure it described.

		IT NEVER THROWS. A cmdlet that fails because it could not write its own
		log has replaced a real problem with a bookkeeping one, and this is
		called from the middle of a sequence that has a disk half-changed.
	#>
	param([Parameter(Mandatory)][string]$Message)

	try {
		$dir = [System.IO.Path]::GetDirectoryName($script:OS7UpdateLog)
		[System.IO.Directory]::CreateDirectory($dir) | Out-Null
		$stamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
		[System.IO.File]::AppendAllText($script:OS7UpdateLog, "$stamp $Message`n")
	}
	catch { }
}

function Get-OS7ReleaseConfField {
	<#
	.SYNOPSIS
		One KEY="value" out of /usr/lib/os7/release.conf. Internal.

	.DESCRIPTION
		The pin is shell, and this file will not run a shell to read it: sourcing
		a file to get one value means anything else in it executes too, and
		docs/SESSION-OS7-REPOSITORY.md §4 records what sourcing that file does to
		an environment that had already set the same names.

		So it is parsed. The grammar is narrow on purpose — NAME=value with
		optional single or double quotes, one per line — because that is all the
		pin uses and a parser that accepts more would accept a line nobody meant.
	#>
	param(
		[Parameter(Mandatory)][string]$Name,
		[string]$Path = $script:OS7ReleaseConf
	)

	if (-not [System.IO.File]::Exists($Path)) { return $null }
	foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
		$t = $line.Trim()
		if (-not $t -or $t.StartsWith('#')) { continue }
		$eq = $t.IndexOf('=')
		if ($eq -lt 1) { continue }
		if ($t.Substring(0, $eq).Trim() -ne $Name) { continue }
		$v = $t.Substring($eq + 1).Trim()
		if ($v.Length -ge 1 -and ($v[0] -eq '"' -or $v[0] -eq "'")) {
			# A quoted value ends at the NEXT matching quote, and anything after
			# it makes the line malformed — loudly. Stripping only the outermost
			# pair turned a glued line (an append onto a file with no trailing
			# newline) into the channel name 'development"OS7_UPDATE_…' and sent
			# the unattended check hunting for an index that cannot exist.
			$close = $v.IndexOf($v[0], 1)
			if ($close -lt 0 -or $v.Substring($close + 1).Trim().Length -gt 0) {
				throw [System.FormatException]::new(
					"$($Path): malformed line for ${Name}: $t")
			}
			$v = $v.Substring(1, $close - 1)
		}
		return $v
	}
	return $null
}

function Get-OS7UpdateSource {
	<#
	.SYNOPSIS
		Where OS/7's own repository is, for this machine. Internal.

	.DESCRIPTION
		In order: what the caller passed, then the URI in the apt source
		os7-release owns, then the pin's OS7_REPO_URI. The apt source comes
		before the pin because Set-OS7UpdateChannel writes it — an operator who
		has pointed this machine somewhere has said something the shipped pin
		has not.

		THE DEFAULT IS A LOCAL PATH THAT NOTHING CREATES, deliberately.
		OS7_REPO_ENABLED ships "no" and OS7_REPO_URI ships
		file:///usr/lib/os7/repo, because nothing is published yet and an apt
		source pointing at a URI that does not resolve prints an error on every
		`apt update` forever. Update-OS7 therefore fails on a stock machine with
		a sentence about Set-OS7UpdateChannel rather than with an apt error.
	#>
	param([string]$Source)

	if ($Source) { return $Source }

	if ([System.IO.File]::Exists($script:OS7AptSource)) {
		foreach ($line in [System.IO.File]::ReadAllLines($script:OS7AptSource)) {
			$t = $line.Trim()
			if ($t -match '^URIs:\s*(\S+)') { return $Matches[1] }
		}
	}
	return (Get-OS7ReleaseConfField -Name 'OS7_REPO_URI')
}

function Get-OS7UpdateChannel {
	<#
	.SYNOPSIS
		Which channel this machine takes releases from. Internal.

	.DESCRIPTION
		What Set-OS7UpdateChannel wrote, and only failing that the channel of
		the build itself.

		THE TWO ARE NOT THE SAME THING and conflating them is what this function
		exists to stop. `Get-OS7Version`'s Channel is the MATURITY of the
		release this machine is running — "development", because nothing has
		shipped. The update channel is where it looks for the next one. A
		machine put on `preview` by an operator would otherwise go on reading
		`index/development.json` and either apply the wrong train or report that
		its channel offers nothing, with no way to tell which.
	#>
	param([string]$Channel)

	if ($Channel) { return $Channel }
	$set = Get-OS7ReleaseConfField -Name 'OS7_UPDATE_CHANNEL' -Path $script:OS7UpdateConf
	if ($set) { return $set }
	$here = [string](Get-OS7Version).Channel
	if ($here) { return $here }
	return 'stable'
}

function Copy-OS7RepoFile {
	<#
	.SYNOPSIS
		Fetch one path out of the repository into a local file. Internal.

	.DESCRIPTION
		Two transports, because the repository is a STATIC TREE
		(CURATION-AND-DELIVERY-PLAN §6.4: "it can be served from anything,
		mirrored into an air-gapped site by copying a directory"). A file:// URI
		is a copy; anything else is curl.

		NOT Invoke-WebRequest. It does not do file://, it does not share apt's
		proxy configuration, and on a machine whose whole update path is apt it
		would be a second answer to "how does this host reach the network".
		curl is already a dependency of the image and is what every other fetch
		in this repository uses.

		A MISSING FILE IS NOT AN ERROR HERE. It is one for the caller to
		describe: "no index for channel X" and "no descriptor for version Y" are
		different sentences and only the caller knows which it is asking for.
	#>
	param(
		[Parameter(Mandatory)][string]$BaseUri,
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][string]$Destination
	)

	$uri = $BaseUri.TrimEnd('/') + '/' + $Path.TrimStart('/')
	if ($uri.StartsWith('file://')) {
		$local = $uri.Substring('file://'.Length)
		if (-not [System.IO.File]::Exists($local)) { return $false }
		[System.IO.File]::Copy($local, $Destination, $true)
		return $true
	}

	# --fail so a 404 is an exit code rather than a file containing an error
	# page, which is the shape that gets hashed and then fails as "signature
	# does not verify" about something that was never a signature.
	try {
		Invoke-OS7Native -Command 'curl' -Arguments @(
			'-fsSL', '--retry', '3', '-o', $Destination, $uri) | Out-Null
	}
	catch { return $false }
	return [System.IO.File]::Exists($Destination)
}

function Test-OS7RepoSignature {
	<#
	.SYNOPSIS
		Verify a detached signature against OS/7's keyring. Internal.

	.DESCRIPTION
		`gpgv`, and NOT `gpg --verify`. gpg verifies against the invoking user's
		keyring and reports an unknown key as a failure of the signature, which
		is a true statement about the wrong question — the question here is
		whether OS/7's own trust anchor signed this file. gpgv takes the keyring
		as an argument and does nothing else, which is what a verifier should be.

		The keyring is the one os7-release ships, so the trust anchor updates
		with the system (CURATION-AND-DELIVERY-PLAN §6.3).
	#>
	param(
		[Parameter(Mandatory)][string]$File,
		[Parameter(Mandatory)][string]$Signature,
		[string]$Keyring = $script:OS7Keyring
	)

	if (-not [System.IO.File]::Exists($Keyring)) {
		throw [System.InvalidOperationException]::new(
			"$Keyring does not exist, so nothing on this machine can verify an OS/7 " +
			'release. It is shipped by the os7-release package.')
	}
	try {
		Invoke-OS7Native -Command 'gpgv' -Arguments @(
			'--keyring', $Keyring, $Signature, $File) | Out-Null
	}
	catch { return $false }
	return $true
}

function Get-OS7FileSha256 {
	<#
	.SYNOPSIS
		Lowercase hex sha256 of a file. Internal.

	.DESCRIPTION
		.NET rather than Get-FileHash, for BUILD-NOTES #38's reason: this module
		is imported by a build hook, and a cmdlet autoloaded by name out of
		$PSHOME/Modules is exactly the lookup live-build's chroot mangles.
		[System.Security.Cryptography] is a type, always present, never looked up.
	#>
	param([Parameter(Mandatory)][string]$Path)

	$sha = [System.Security.Cryptography.SHA256]::Create()
	try {
		$stream = [System.IO.File]::OpenRead($Path)
		try {
			$bytes = $sha.ComputeHash($stream)
			$hex = [System.BitConverter]::ToString($bytes)
			return $hex.Replace('-', '').ToLowerInvariant()
		}
		finally { $stream.Dispose() }
	}
	finally { $sha.Dispose() }
}


# ---------------------------------------------------------------------------
# The index and the descriptors
# ---------------------------------------------------------------------------

function Get-OS7ReleaseIndex {
	<#
	.SYNOPSIS
		The signed release index for a channel, verified. Internal.

	.DESCRIPTION
		CURATION-AND-DELIVERY-PLAN §6.4. One signed static file per channel,
		with no service behind it.

		THREE THINGS ARE CHECKED AND ALL THREE ARE SEPARATE PROPERTIES.
		The signature says OS/7 wrote this. `valid_until` says it is still the
		current answer — §6.3: "A signed package set with an unsigned index of
		WHICH set is current lets an attacker serve an older, still-validly-
		signed release. Freshness is a separate property from authenticity." And
		the per-release `manifest_sha256`, checked in Get-OS7ReleaseDescriptor,
		is what binds a descriptor to the index that named it.

		-SkipSignature exists for one caller: Test-OS7Update, which builds an
		index in a temporary directory to check the reader's own decisions. It
		is not a parameter of any public cmdlet.
	#>
	param(
		[Parameter(Mandatory)][string]$BaseUri,
		[Parameter(Mandatory)][string]$Channel,
		[string]$WorkDir,
		[switch]$SkipSignature
	)

	if (-not $WorkDir) { $WorkDir = [System.IO.Path]::GetTempPath() }
	$json = [System.IO.Path]::Combine($WorkDir, "os7-index-$Channel.json")
	$asc  = "$json.asc"

	if (-not (Copy-OS7RepoFile -BaseUri $BaseUri -Path "index/$Channel.json" -Destination $json)) {
		throw [System.InvalidOperationException]::new(
			"no release index for channel '$Channel' at $BaseUri. Either the channel is " +
			'wrong or this machine is pointed at something that is not an OS/7 repository ' +
			'— see Set-OS7UpdateChannel.')
	}

	if (-not $SkipSignature) {
		if (-not (Copy-OS7RepoFile -BaseUri $BaseUri -Path "index/$Channel.json.asc" -Destination $asc)) {
			throw [System.InvalidOperationException]::new(
				"the release index at $BaseUri is not signed. An unsigned index is how an " +
				'older, still-validly-signed release gets served forever ' +
				'(CURATION-AND-DELIVERY-PLAN §6.3).')
		}
		if (-not (Test-OS7RepoSignature -File $json -Signature $asc)) {
			throw [System.InvalidOperationException]::new(
				"the release index at $BaseUri is signed by a key this machine does not " +
				"trust. The trust anchor is $($script:OS7Keyring), shipped by os7-release.")
		}
	}

	$doc = ConvertFrom-Json ([System.IO.File]::ReadAllText($json))

	# The file was FETCHED by channel name and the document SAYS which channel
	# it is, and the two must agree. A signed index served under the wrong name
	# is not a corrupt file — the signature verifies — it is a stable channel
	# answering with a development listing, or the reverse, and every decision
	# downstream (Applicable, the operator's own reading) would be made against
	# the wrong population. Channels became real on 2026-08-28; before that
	# there was only one and this could not fire.
	$docChannel = [string](Get-OS7ManifestField $doc 'channel')
	if ($docChannel -ne $Channel) {
		throw [System.InvalidOperationException]::new(
			"the index fetched as channel '$Channel' says it is channel '$docChannel'. " +
			'A mislabelled index is refused: its signature proves who wrote it, not ' +
			'that it is the channel it was asked for.')
	}

	# Freshness, and it is checked HERE rather than left to the caller because a
	# reader that returns a stale index has already answered the question.
	$validUntil = [string](Get-OS7ManifestField $doc 'valid_until')
	if ($validUntil) {
		# " UTC" -> " GMT" BEFORE PARSING, and this is not cosmetic.
		#
		# RFC 1123 spells the zone GMT, and that is what .NET accepts. Both forms
		# are in circulation here: apt-ftparchive writes `+0000` into the Release
		# file, and `date -u +'%a, %d %b %Y %H:%M:%S UTC'` — which is what
		# build-os7-repo.sh composed before it started reading the Release file
		# back — writes UTC. TryParse rejects the third form.
		#
		# MEASURED 2026-08-27 by installer/testing/check-update-logic.py, which
		# built an index with the UTC spelling: the parse failed, the failure was
		# a WARNING, and an expired index was therefore ACCEPTED. A freshness
		# check that cannot read the date is a freshness check that is not
		# running, and §6.3 puts it there to stop a withdrawn release being
		# served forever. BUILD-NOTES #90.
		$normalised = [regex]::Replace($validUntil, '\sUTC$', ' GMT')
		$when = [datetime]::MinValue
		if ([datetime]::TryParse($normalised, [cultureinfo]::InvariantCulture,
				[System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$when)) {
			if ($when -lt [datetime]::UtcNow) {
				throw [System.InvalidOperationException]::new(
					"the release index for '$Channel' expired on $validUntil. It is signed " +
					'and it is no longer current; refusing rather than applying a release ' +
					'that may have been withdrawn.')
			}
		}
		else {
			# REFUSE, do not warn. A freshness check that cannot read the date
			# is a freshness check that is not running, and the standing rule in
			# this repository is that a check which did not run must never read
			# as a clean result — the same rule that keeps Get-OS7Version's
			# Drift empty rather than $false until it is asked for.
			throw [System.InvalidOperationException]::new(
				"the release index for '$Channel' carries a valid_until this machine " +
				"cannot read ('$validUntil'), so its freshness cannot be established. " +
				'Refusing rather than applying a release that may have been withdrawn.')
		}
	}
	else {
		throw [System.InvalidOperationException]::new(
			"the release index for '$Channel' carries no valid_until at all. An index " +
			'that never expires lets an older, still-validly-signed release be served ' +
			'forever (CURATION-AND-DELIVERY-PLAN §6.3).')
	}
	return $doc
}

function Get-OS7ReleaseDescriptor {
	<#
	.SYNOPSIS
		One release's descriptor, bound to the index that named it. Internal.

	.DESCRIPTION
		C9: "the release descriptor is the product, and the ISO is one way of
		materialising it." This is the file that says what a release contains.

		THE HASH IS THE BINDING. The descriptor is not signed on its own; the
		INDEX is signed, and it records each descriptor's sha256. So a
		descriptor is trusted exactly as far as the index that names it, which
		is why this function will not fetch one without an index entry to check
		it against.
	#>
	param(
		[Parameter(Mandatory)][string]$BaseUri,
		[Parameter(Mandatory)]$IndexEntry,
		[string]$WorkDir
	)

	if (-not $WorkDir) { $WorkDir = [System.IO.Path]::GetTempPath() }
	$version = [string](Get-OS7ManifestField $IndexEntry 'version')
	$path    = [string](Get-OS7ManifestField $IndexEntry 'manifest')
	$want    = [string](Get-OS7ManifestField $IndexEntry 'manifest_sha256')
	if (-not $path) {
		# The builder always writes `manifest`; this reconstructs its layout
		# for an entry that lost the field. The architecture joined the path
		# when two of them started sharing one repository (RELEASE-PROCESS
		# §7.3); an entry too old to name its architecture predates that
		# layout, so it gets the flat one.
		$entryArch = [string](Get-OS7ManifestField $IndexEntry 'architecture')
		$path = if ($entryArch) { "releases/$version/$entryArch/release.json" }
		else { "releases/$version/release.json" }
	}

	$file = [System.IO.Path]::Combine($WorkDir, "os7-release-$version.json")
	if (-not (Copy-OS7RepoFile -BaseUri $BaseUri -Path $path -Destination $file)) {
		throw [System.InvalidOperationException]::new(
			"the index names release $version at '$path' and there is nothing there.")
	}

	# NO HASH IS A REFUSAL, not a note.
	#
	# The descriptor is not signed on its own — the INDEX is, and it records the
	# descriptor's sha256. So an index entry with no manifest_sha256 names a
	# file that NOTHING signed, and accepting it with a log line is the whole
	# verification path failing open. This function is the only thing standing
	# between a release descriptor and being applied.
	#
	# BUILD-NOTES #90 is the same rule, written the same day about the freshness
	# check next door: a check that cannot run must never read as a check that
	# passed.
	if (-not $want) {
		throw [System.InvalidOperationException]::new(
			"the signed index records no sha256 for $version, so its descriptor is bound " +
			'to nothing. Refusing rather than applying a release whose contents no ' +
			'signature covers.')
	}
	$got = Get-OS7FileSha256 -Path $file
	if ($got -ne $want.ToLowerInvariant()) {
		throw [System.InvalidOperationException]::new(
			"the descriptor for $version does not match the hash the signed index " +
			"records for it.`n  index: $want`n  file:  $got")
	}
	return (ConvertFrom-Json ([System.IO.File]::ReadAllText($file)))
}

function Compare-OS7Version {
	<#
	.SYNOPSIS
		-1, 0 or 1 for two four-field OS/7 versions. Internal.

	.DESCRIPTION
		[version] and not a string compare, and the difference is not academic:
		"1.0.0.9" sorts above "1.0.0.31" as a string. That exact mistake is live
		in this module's kernel picker and is what BUILD-NOTES #89 is about.
	#>
	param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)

	$l = [version]'0.0.0.0'; $r = [version]'0.0.0.0'
	if (-not [version]::TryParse($Left, [ref]$l)) {
		throw [ArgumentException]::new("'$Left' is not a version", 'Left')
	}
	if (-not [version]::TryParse($Right, [ref]$r)) {
		throw [ArgumentException]::new("'$Right' is not a version", 'Right')
	}
	return $l.CompareTo($r)
}


# ---------------------------------------------------------------------------
# The public read surface
# ---------------------------------------------------------------------------

function Get-OS7Release {
	<#
	.SYNOPSIS
		What OS/7 releases this machine's channel offers.

	.DESCRIPTION
		docs/RELEASE-AND-UPDATE-PLAN.md §6: "What the channel offers, without
		applying it." It is what makes `Update-OS7 -WhatIf` able to report
		anything at all.

		EVERY RELEASE IS VERIFIED BEFORE IT IS LISTED. The index's signature and
		expiry are checked by Get-OS7ReleaseIndex, and each descriptor against
		the sha256 the index records. A listing that showed unverified releases
		would be a listing an operator could act on, which makes it part of the
		trust path and not a convenience.

		`Applicable` is the property to read before `Update-OS7`: it is $false
		for a release that is not newer than this machine, for one that would
		cross a Major — which C12 says this train must refuse rather than
		attempt — and for one built for another architecture, which becomes
		possible the moment one repository URL serves both (RELEASE-PROCESS.md
		§7.3). Each reason is also its own property (`Newer`, `CrossesMajor`,
		`ForeignArchitecture`, `Hotfix`), because "not applicable" for four
		different reasons is four different conversations with the operator.

	.PARAMETER Available
		List what the channel offers. Present because §6 names the cmdlet
		`Get-OS7Release -Available`; without it the cmdlet reports the running
		release, which is Get-OS7Version's job, so it is effectively the only
		mode and is the default.

	.PARAMETER Channel
		Which channel to read. Defaults to the machine's own, from the pin.

	.PARAMETER Source
		A repository URI, overriding the machine's. For a mirror, an offline
		bundle, or a harness.

	.EXAMPLE
		Get-OS7Release -Available

	.EXAMPLE
		Get-OS7Release -Source file:///mnt/usb/os7-repo | Where-Object Applicable
	#>
	[CmdletBinding()]
	[OutputType('OS7.Release')]
	param(
		[switch]$Available,
		[string]$Channel,
		[string]$Source
	)

	$here = Get-OS7Version
	$base = Get-OS7UpdateSource -Source $Source
	if (-not $base) {
		throw [System.InvalidOperationException]::new(
			'this machine has no OS/7 repository configured. Point it at one with ' +
			'Set-OS7UpdateChannel -Uri <uri>, or pass -Source.')
	}
	$Channel = Get-OS7UpdateChannel -Channel $Channel

	$work = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
		'os7-release-' + [System.Diagnostics.Process]::GetCurrentProcess().Id)
	[System.IO.Directory]::CreateDirectory($work) | Out-Null
	try {
		$index = Get-OS7ReleaseIndex -BaseUri $base -Channel $Channel -WorkDir $work
		$mine  = [string]$here.FullVersion
		$myMajor = if ($mine) { ([version]$mine).Major } else { -1 }

		foreach ($entry in @(Get-OS7ManifestField $index 'releases')) {
			$version = [string](Get-OS7ManifestField $entry 'version')
			if (-not $version) { continue }
			$descriptor = Get-OS7ReleaseDescriptor -BaseUri $base -IndexEntry $entry -WorkDir $work
			$signing = Get-OS7ManifestField $descriptor 'signing'

			$major = ([version]$version).Major
			$newer = $mine -and (Compare-OS7Version -Left $version -Right $mine) -gt 0

			# The hotfix form (§7): a release that overlays a BASE release and
			# is applicable only to a machine ON that base. The base is read
			# from the signed index's entry and cross-checked against the
			# descriptor the entry's hash binds — the two are one author
			# (build-os7-repo.sh derives the entry from the descriptor), so a
			# difference is tampering or a builder defect, and both are
			# refusals rather than judgement calls.
			$entryHotfixBase = [string](Get-OS7ManifestField $entry 'hotfix_base')
			$descHotfix      = Get-OS7ManifestField $descriptor 'hotfix'
			$descHotfixBase  = if ($null -ne $descHotfix) {
				[string](Get-OS7ManifestField $descHotfix 'base') } else { '' }
			if ($entryHotfixBase -ne $descHotfixBase) {
				throw [System.InvalidOperationException]::new(
					"release $version names hotfix base '$entryHotfixBase' in the index and " +
					"'$descHotfixBase' in its descriptor. The two have one author; a " +
					'difference means one of them is not the file that was published.')
			}
			$onBase = (-not $entryHotfixBase) -or
				($mine -and (Compare-OS7Version -Left $entryHotfixBase -Right $mine) -eq 0)

			# THE ARCHITECTURE IS COMPARED, not assumed. Harmless while every
			# repository serves one architecture; wrong the moment one URL
			# serves both (RELEASE-PROCESS.md §7.3): an amd64 machine would
			# list an arm64 release as Applicable and Update-OS7 would fail
			# late, inside apt, about packages rather than about the reason.
			# Only a POSITIVE mismatch blocks — a side that does not state its
			# architecture is today's single-arch world, not a refusal.
			$entryArch = [string](Get-OS7ManifestField $entry 'architecture')
			$myArch    = [string]$here.Architecture
			$foreignArch = [bool]($entryArch -and $myArch -and $entryArch -ne $myArch)

			[pscustomobject]@{
				PSTypeName   = 'OS7.Release'
				Version      = $version
				Channel      = [string](Get-OS7ManifestField $index 'channel')
				Released     = [string](Get-OS7ManifestField $entry 'released')
				Architecture = $entryArch
				Suite        = [string](Get-OS7ManifestField $entry 'os7_suite')
				Snapshot     = [string](Get-OS7ManifestField $entry 'archive_snapshot')
				# Whether Update-OS7 would take it. Every half is said
				# separately, because "not applicable" for four different
				# reasons is four different conversations with the operator.
				Applicable   = ($newer -and $major -eq $myMajor -and $onBase -and -not $foreignArch)
				Newer        = [bool]$newer
				CrossesMajor = ($major -ne $myMajor)
				ForeignArchitecture = $foreignArch
				# §7: a hotfix moves the Build field alone and overlays exactly
				# the base release it names. On any other machine it is listed
				# and not applicable — the operator updates to the base first.
				Hotfix       = [bool]$entryHotfixBase
				HotfixBase   = $(if ($entryHotfixBase) { $entryHotfixBase } else { $null })
				# C7a is open, so this is load-bearing rather than informational:
				# Update-OS7 refuses a development release without
				# -AllowDevelopment, and this is where an operator sees why.
				#
				# A DESCRIPTOR WITH NO `signing` BLOCK IS DEVELOPMENT, not
				# published. `Get-OS7ManifestField` returns $null for a field
				# that is not there and [bool]$null is $false, so reading it
				# directly would make "this release says nothing about how it
				# was signed" indistinguishable from "this release says it was
				# signed for production" — and the switch that exists to make an
				# operator say that out loud would not be required.
				# Unknown provenance is not provenance.
				Development  = $(if ($null -eq $signing) { $true }
					else { [bool](Get-OS7ManifestField $signing 'development') })
				SigningKey   = $(if ($null -eq $signing) { '(the descriptor names no key)' }
					else { [string](Get-OS7ManifestField $signing 'key') })
				Migrations   = @(Get-OS7ManifestField $entry 'migrations')
				Descriptor   = $descriptor
			}
		}
	}
	finally {
		[System.IO.Directory]::Delete($work, $true)
	}
}

function Set-OS7UpdateChannel {
	<#
	.SYNOPSIS
		Point this machine at an OS/7 repository, and choose its channel.

	.DESCRIPTION
		docs/RELEASE-AND-UPDATE-PLAN.md §6 names this verb for channel
		selection. It does one more thing than the name suggests, and it has to:
		the apt source os7-release ships is `Enabled: no` at a `file://` path
		nothing creates, because nothing is published yet and a source pointing
		at a URI that does not resolve prints an error on every `apt update`
		forever (docs/SESSION-OS7-REPOSITORY.md §4). So this is also the verb
		that switches it on.

		IT REWRITES THE FILE os7-release OWNS. That is deliberate and it is not a
		conffile fight: the package ships the source disabled and this is the
		supported way to enable it, exactly as `pro config set` is for Ubuntu's.
		A dpkg upgrade of os7-release will put the shipped version back — which
		is why -Uri is recorded in the file itself and not somewhere else, so
		the next run of this cmdlet can be told what the last one said.

	.PARAMETER Channel
		stable, preview or development. The channel is what the index is named
		after; it is not the same thing as maturity of the running build, which
		is Get-OS7Version's Channel.

	.PARAMETER Uri
		The repository. Without it, whatever the machine already has.

	.PARAMETER Disable
		Switch the source off again, leaving it declared. The honest state for a
		machine that should not update.

	.EXAMPLE
		Set-OS7UpdateChannel -Channel stable -Uri https://releases.example/os7

	.EXAMPLE
		Set-OS7UpdateChannel -Disable
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	[OutputType('OS7.UpdateChannel')]
	param(
		[ValidateSet('stable', 'preview', 'development')]
		[string]$Channel,
		[string]$Uri,
		[switch]$Disable
	)

	$suite = Get-OS7ReleaseConfField -Name 'OS7_SUITE'
	if (-not $suite) {
		throw [System.InvalidOperationException]::new(
			"$($script:OS7ReleaseConf) names no OS7_SUITE. Without it there is no suite to " +
			'write into an apt source, and this machine cannot be pointed at an OS/7 ' +
			'repository at all.')
	}

	$current = Get-OS7UpdateSource
	if (-not $Uri) { $Uri = $current }
	if (-not $Uri) {
		throw [System.InvalidOperationException]::new(
			'no repository URI: this machine has none configured and none was given. ' +
			'Pass -Uri.')
	}

	$arch = Invoke-OS7Native -Command 'dpkg' -Arguments @('--print-architecture')
	$arch = ([string]$arch).Trim()
	$enabled = if ($Disable) { 'no' } else { 'yes' }

	$body = @(
		"# OS/7's own repository. CURATION-AND-DELIVERY-PLAN.md C7."
		'# Written by Set-OS7UpdateChannel. os7-release ships this file disabled;'
		'# this is the supported way to switch it on.'
		'Types: deb'
		"URIs: $Uri"
		"Suites: $suite"
		'Components: main'
		"Architectures: $arch"
		"Signed-By: $($script:OS7Keyring)"
		"Enabled: $enabled"
	) -join "`n"

	if ($PSCmdlet.ShouldProcess($script:OS7AptSource,
			"point at $Uri, suite $suite, enabled=$enabled")) {
		[System.IO.Directory]::CreateDirectory(
			[System.IO.Path]::GetDirectoryName($script:OS7AptSource)) | Out-Null
		[System.IO.File]::WriteAllText($script:OS7AptSource, $body + "`n")

		# THE CHANNEL IS RECORDED, or this cmdlet does not do the thing it is
		# named after. The apt source has nowhere to put it and the suite is
		# per-Major, so without this file `-Channel preview` returned an object
		# saying preview and changed nothing an updater reads.
		if ($Channel) {
			[System.IO.Directory]::CreateDirectory(
				[System.IO.Path]::GetDirectoryName($script:OS7UpdateConf)) | Out-Null
			# The trailing newline is load-bearing: this is a KEY="value" file
			# an operator appends to (OS7_UPDATE_UNATTENDED_ALLOW_DEVELOPMENT,
			# per the timer's log message), and without it the first `echo >>`
			# glues onto the channel line and corrupts BOTH settings. Measured:
			# the timer read channel 'development"OS7_UPDATE_UNATTENDED_…'.
			[System.IO.File]::WriteAllText($script:OS7UpdateConf, (@(
				'# OS/7 — where this machine looks for its next release.'
				'# Written by Set-OS7UpdateChannel. The repository URI is in'
				"# $($script:OS7AptSource); this is the channel within it."
				"OS7_UPDATE_CHANNEL=`"$Channel`""
			) -join "`n") + "`n")

			# Read it back. A file that was written is not a file that parses,
			# and the next thing to read it is an unattended timer.
			$got = Get-OS7ReleaseConfField -Name 'OS7_UPDATE_CHANNEL' -Path $script:OS7UpdateConf
			if ($got -ne $Channel) {
				throw [System.InvalidOperationException]::new(
					"wrote the channel and read back '$got'.")
			}
		}

		# ASK apt, not the file. A source file that parses is not a source apt
		# accepted: a bad Signed-By path, a suite with no Release file, or a URI
		# that does not resolve all leave the file exactly as written and apt
		# reporting nothing from it.
		if (-not $Disable) {
			try { Invoke-OS7Native -Command 'apt-get' -Arguments @('-qq', 'update') | Out-Null }
			catch {
				throw [System.InvalidOperationException]::new(
					"the source was written and apt will not read it:`n$($_.Exception.Message)")
			}
		}
	}

	[pscustomobject]@{
		PSTypeName = 'OS7.UpdateChannel'
		# What is IN FORCE after this call, read back rather than echoed.
		Channel    = Get-OS7UpdateChannel
		Uri        = $Uri
		Suite      = $suite
		Enabled    = (-not $Disable)
		SourceFile = $script:OS7AptSource
		Keyring    = $script:OS7Keyring
	}
}


# ---------------------------------------------------------------------------
# Step 3 — assembling a boot environment
# ---------------------------------------------------------------------------

function Get-OS7MountedPaths {
	<#
	.SYNOPSIS
		Every mount point the kernel currently has, as a set. Internal.

	.DESCRIPTION
		/proc/self/mountinfo and not the output of `mount`, because this is the
		question a chroot depends on and the kernel is the only thing that
		actually knows the answer. Field 5 is the mount point, with octal
		escapes for the characters that would break the format.
	#>
	param([string]$Path = '/proc/self/mountinfo')

	$set = @{}
	if (-not [System.IO.File]::Exists($Path)) { return $set }
	foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
		$f = $line.Split(' ')
		if ($f.Count -lt 5) { continue }
		$mp = $f[4] -replace '\\040', ' ' -replace '\\011', "`t" -replace '\\134', '\'
		$set[$mp] = $true
	}
	return $set
}

function Mount-OS7UpdateRoot {
	<#
	.SYNOPSIS
		Assemble a boot environment so apt can run against it. Internal.

	.DESCRIPTION
		§4.2 step 3, and the order below is the order spike S5 used on a machine
		that then booted (installer/testing/run-s5.py ASSEMBLE). It is followed
		rather than paraphrased, because BUILD-NOTES #66 is the record of what
		happens when code that replaces a spike takes a different route from the
		same notes.

		WHERE IT DIFFERS FROM S5, AND WHY. S5 bound only /var/log, because that
		was all its one assertion needed. §4.2 step 3 says "mount the rpool/DATA
		datasets into it … so apt sees a whole /var", and a postinst that writes
		to /var/lib/NetworkManager or to an agent's state directory would
		otherwise write into the clone's ROOT dataset — where a rollback would
		take it, which is the exact thing §4.4 moved those datasets out to
		prevent. So every rpool/DATA dataset with a real mountpoint is bound in.

		A BIND OF THE RUNNING MOUNT, NOT A SECOND `mount -t zfs`. The dataset is
		already mounted at its own mountpoint on the running system; mounting it
		a second time somewhere else would give apt a second view of one
		filesystem. S5 used --bind for /var/log for this reason and it
		generalises.

		NOT `zfs mount`. The clone's root carries mountpoint=/ — deliberately,
		because GRUB's generator finds boot environments by that property — so
		`zfs mount` would put it over the running root.
	#>
	param(
		[Parameter(Mandatory)][string]$Name,
		[string]$Root = $script:OS7UpdateRoot,
		[switch]$WhatIf
	)

	Import-OS7ZfsLayer
	$rootDs = "$($script:OS7RootParent)/$Name"
	$bootDs = "$($script:OS7BootParent)/$Name"

	Write-OS7Step "assembling $Name at $Root"
	[System.IO.Directory]::CreateDirectory($Root) | Out-Null

	# WHAT WAS MOUNTED, COLLECTED AS IT HAPPENS AND RETURNED.
	#
	# Assert-OS7UpdateRootAssembled used to be handed a list the CALLER composed
	# from the paths it expected — four of them, hard-coded — which asks a
	# different question from the one that matters. The question is whether
	# everything this function mounted is mounted, and only this function knows
	# what that was: the in-BE children come from ZFS, and so do the rpool/DATA
	# binds, precisely so that a layout which gains a dataset does not need this
	# file edited.
	$mounted = [System.Collections.Generic.List[string]]::new()

	$zfsMount = {
		param($dataset, $at)
		[System.IO.Directory]::CreateDirectory($at) | Out-Null
		Invoke-OS7Native -Command 'mount' -Arguments @(
			'-t', 'zfs', '-o', 'zfsutil', $dataset, $at) -WhatIf:$WhatIf | Out-Null
		$mounted.Add($at)
	}

	& $zfsMount $rootDs $Root

	# The in-BE children, in dataset order so a parent is mounted before its
	# child. canmount=off datasets are containers and have nothing to mount.
	foreach ($d in @(Get-ZfsDataset -Name $rootDs -Recurse -Type Filesystem | Sort-Object Name)) {
		if ($d.Name -eq $rootDs) { continue }
		$cm = Get-OS7ZfsPropertyValue -Name $d.Name -Property 'canmount'
		if ([string]$cm -eq 'off') { continue }
		$mp = Get-OS7ZfsPropertyValue -Name $d.Name -Property 'mountpoint'
		$mp = [string]$mp
		if (-not $mp -or $mp -eq 'none' -or $mp -eq 'legacy') { continue }
		& $zfsMount $d.Name ($Root + $mp)
	}

	# The bpool half. AFTER the root and BEFORE the ESP bind, or the ESP goes
	# under a directory that is about to be covered.
	& $zfsMount $bootDs ($Root + '/boot')

	# The ESP is ONE partition shared by every boot environment — it is not
	# per-BE and must not be cloned into one. A bind is the only correct way to
	# give the clone the ESP the machine actually boots from — and it must BE
	# mounted first, or the bind carries an empty directory into the chroot
	# and grub's postinst writes into a hole (#104's other half). Guarded on
	# the directory existing, because the bind loop below already SKIPS absent
	# mountpoints — check-update-logic's world has no /boot/efi at all, and a
	# world without the directory is not a world with an unmounted ESP.
	if ([System.IO.Directory]::Exists('/boot/efi')) { Assert-OS7EspMounted }
	$binds = @('/boot/efi')

	# Every out-of-BE dataset, by its mountpoint (§4.4). Read from ZFS rather
	# than listed here, so a layout that gains a dataset does not need this file
	# edited — which is how the list would fall behind.
	foreach ($d in @(Get-ZfsDataset -Name 'rpool/DATA' -Recurse -Type Filesystem -ErrorAction SilentlyContinue)) {
		$mp = Get-OS7ZfsPropertyValue -Name $d.Name -Property 'mountpoint'
		$mp = [string]$mp
		if (-not $mp -or $mp -eq 'none' -or $mp -eq 'legacy') { continue }
		$binds += $mp
	}

	# EVERY CONCATENATION IN AN ARGUMENT LIST IS PARENTHESISED, and that is not
	# style. Measured 2026-08-27:
	#
	#   @('--bind', $mp, $Root + $mp)     -> FOUR elements
	#   @('--bind', $mp, ($Root + $mp))   -> three
	#
	# The comma binds tighter than the `+` in that position, so the expression
	# that reads as a concatenation is a list. It produced
	# `mount --bind /srv /run/os7-update /srv`, which mount rejected — loudly,
	# by luck. The same shape one argument earlier would have produced a VALID
	# command against the wrong path. BUILD-NOTES #91.
	foreach ($mp in ($binds | Sort-Object -Unique)) {
		if (-not [System.IO.Directory]::Exists($mp)) { continue }
		[System.IO.Directory]::CreateDirectory($Root + $mp) | Out-Null
		Invoke-OS7Native -Command 'mount' -Arguments @('--bind', $mp, ($Root + $mp)) `
			-WhatIf:$WhatIf | Out-Null
		# --make-slave IMMEDIATELY, and it is load-bearing: on a systemd system
		# every mount is shared, so a plain bind JOINS ITS SOURCE'S PEER GROUP
		# — the bind of /boot/efi and the real /boot/efi become peers, and a
		# mount event under one propagates to the other. The first end-to-end
		# update run ended with the RUNNING MACHINE's ESP unmounted at
		# activation time, after the dismount had taken the assembly apart
		# (#104). A slave receives events and sends none, which is exactly the
		# relationship a scaffold should have to the machine it is built
		# against — the same reasoning the rbinds below have carried all
		# along, now applied to every bind.
		Invoke-OS7Native -Command 'mount' -Arguments @('--make-slave', ($Root + $mp)) `
			-WhatIf:$WhatIf | Out-Null
		$mounted.Add($Root + $mp)
	}

	# --rbind and --make-rslave: /dev carries submounts (devpts, shm) that a
	# plain --bind would not bring, and rslave keeps anything the chroot mounts
	# from propagating back out into the running system's namespace.
	foreach ($d in @('/dev', '/proc', '/sys', '/run')) {
		[System.IO.Directory]::CreateDirectory($Root + $d) | Out-Null
		Invoke-OS7Native -Command 'mount' -Arguments @('--rbind', $d, ($Root + $d)) -WhatIf:$WhatIf | Out-Null
		Invoke-OS7Native -Command 'mount' -Arguments @('--make-rslave', ($Root + $d)) -WhatIf:$WhatIf | Out-Null
		$mounted.Add($Root + $d)
	}

	# Name resolution inside the chroot. /etc is in the boot environment, so the
	# clone has whatever the running system had when it was cloned — which on a
	# systemd-resolved machine is a symlink into /run, already bound above. A
	# copy is made only when there is nothing readable there, and it is removed
	# again by Dismount-OS7UpdateRoot.
	#
	# AND IT IS SKIPPED WHEN THE ENVIRONMENT HAS NO /etc, rather than creating
	# one. /etc is inside the boot environment, so an assembled clone without it
	# is not an environment that could ever have booted — writing a resolv.conf
	# into a directory this function invented would hide that behind a name
	# resolution failure ten steps later.
	$resolv = $Root + '/etc/resolv.conf'
	if (-not $WhatIf) {
		if (-not [System.IO.Directory]::Exists($Root + '/etc')) {
			Write-OS7Step "the assembled environment has no /etc — not writing a resolv.conf into it"
		}
		elseif (-not [System.IO.File]::Exists($resolv) -and
				[System.IO.File]::Exists('/etc/resolv.conf')) {
			[System.IO.File]::Copy('/etc/resolv.conf', $resolv, $true)
		}
	}

	return @($mounted)
}

function Assert-OS7UpdateRootAssembled {
	<#
	.SYNOPSIS
		Refuse to chroot into a partly assembled boot environment. Internal.

	.DESCRIPTION
		THE CHECK THIS FILE EXISTS FOR. A clone's datasets are all
		canmount=noauto, so nothing mounts itself and a mount that did not
		happen leaves an empty directory that reads exactly like an empty
		filesystem. apt would then run, dpkg would write into the clone's root
		dataset where /var/log and the agent state should have been, and the
		damage would surface at the rollback that was supposed to preserve them.

		So the kernel is asked — /proc/self/mountinfo — and the answer must
		include every path that was supposed to be mounted. `mount` exiting 0 is
		a diagnostic; this is the fact.
	#>
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string[]]$Expected
	)

	$have = Get-OS7MountedPaths
	$missing = @($Expected | Where-Object { -not $have.ContainsKey($_) })
	if ($missing.Count -gt 0) {
		throw [System.InvalidOperationException]::new(
			"the boot environment at $Root is not fully assembled. The kernel reports no " +
			"mount at:`n  " + ($missing -join "`n  ") +
			"`nRunning apt against it would write package state into the environment's own " +
			'root dataset, where a rollback would take it with the system.')
	}
	# /dev has to be more than a mount point: .NET applications in the chroot —
	# and apt's own maintainer scripts — need a working RNG, and a /dev that is
	# mounted but empty is the shape BUILD-NOTES #14 describes.
	if (-not [System.IO.File]::Exists($Root + '/dev/urandom')) {
		throw [System.InvalidOperationException]::new(
			"$Root/dev is mounted and has no urandom. Nothing that needs entropy will " +
			'work inside it, and the failures name everything except /dev.')
	}
}

function Dismount-OS7UpdateRoot {
	<#
	.SYNOPSIS
		Take the assembly down, deepest first. Internal.

	.DESCRIPTION
		Reverse path order, which is what makes a child unmount before its
		parent without keeping a list. Lazily (-l), because a process that
		wandered into the tree — and on a machine running an update there will
		be one — would otherwise hold the whole thing.

		IT MUST NOT THROW. This runs in a finally block, and an exception here
		would replace whatever went wrong upstream with a message about a mount
		point. What it does instead is REPORT what is still mounted, and the
		caller decides: an environment left with mounts is one the BE cmdlets
		must not be pointed at, because Get-OS7BootEnvironment's Active is ZFS's
		`mounted` and a still-mounted clone reads as a second active environment.
	#>
	param([string]$Root = $script:OS7UpdateRoot)

	$paths = @(Get-OS7MountedPaths).Keys |
		Where-Object { $_ -eq $Root -or $_.StartsWith($Root + '/') } |
		Sort-Object -Descending

	foreach ($p in $paths) {
		try { Invoke-OS7Native -Command 'umount' -Arguments @('-l', $p) | Out-Null }
		catch { Write-OS7Step "could not unmount $p" }
	}

	$left = @(Get-OS7MountedPaths).Keys |
		Where-Object { $_ -eq $Root -or $_.StartsWith($Root + '/') }
	if ($left) {
		Write-OS7Step ("still mounted under ${Root}: " + ($left -join ' '))
	}
	return @($left)
}

function Invoke-OS7InRoot {
	<#
	.SYNOPSIS
		Run a command inside the assembled boot environment. Internal.

	.DESCRIPTION
		`chroot`, and not `apt-get -o Dir::RootDir=`. The second looks tidier and
		is not the same operation: maintainer scripts run against the RUNNING
		system's /usr under RootDir, so a postinst that restarts a service or
		rebuilds an initramfs would act on the machine rather than on the
		environment being built. §4.2 step 3 says chroot, S5 chrooted, and the
		machine that booted afterwards is the evidence.
	#>
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string[]]$Command,
		[switch]$WhatIf
	)

	return (Invoke-OS7Native -Command 'chroot' -Arguments (@($Root) + $Command) -WhatIf:$WhatIf)
}


# ---------------------------------------------------------------------------
# Step 6' — migrations
# ---------------------------------------------------------------------------

function Get-OS7Migration {
	<#
	.SYNOPSIS
		The migration scripts a release declares, in order. Internal.

	.DESCRIPTION
		C10: migrations are "declared in the release descriptor, ship in
		os7-release, and must be idempotent because a rollback followed by a
		re-update runs them twice."

		THE CONTRACT, which no document had written down and this file therefore
		decides:

		  /usr/lib/os7/migrations/<version>/<context>/NN-name

		<version> is the release that INTRODUCED the migration. <context> is
		`chroot` or `firstboot`, and the split is forced by BUILD-NOTES #69:
		C10 names TPM2 re-enrolment after a PCR 7 move as migration content, and
		sealing to PCR 7 from a chroot seals against the chroot's PCR 7, not the
		installed machine's. So a migration that must see the real boot cannot
		run here at all. `chroot` migrations run inside the assembled
		environment before update-initramfs; `firstboot` ones are recorded in
		the environment for something on the target's first boot to run, and
		this cmdlet says out loud that it has left work behind.

		NN- ORDERS THEM, and it is a two-digit numeric prefix rather than a
		lexical sort of the whole name for the reason BUILD-NOTES #89 records:
		a string sort puts 9 above 31.
	#>
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string]$Version,
		[ValidateSet('chroot', 'firstboot')][string]$Context = 'chroot'
	)

	$dir = [System.IO.Path]::Combine($Root.TrimEnd('/') + $script:OS7MigrationDir, $Version, $Context)
	if (-not [System.IO.Directory]::Exists($dir)) { return @() }

	$files = @([System.IO.Directory]::GetFiles($dir))
	# Numeric prefix first, then the name, so 09 and 9 sort together and 31
	# lands after 9 rather than before it.
	return @($files | Sort-Object `
		@{ Expression = { $n = 0; [void][int]::TryParse(
			([System.IO.Path]::GetFileName($_) -split '-')[0], [ref]$n); $n } },
		@{ Expression = { [System.IO.Path]::GetFileName($_) } })
}

function Invoke-OS7Migration {
	<#
	.SYNOPSIS
		Run one release's chroot migrations, once. Internal.

	.DESCRIPTION
		IDEMPOTENCE IS THE MIGRATION'S JOB AND THE RECORD IS THIS FUNCTION'S.
		C10 requires migrations to be idempotent because a rollback followed by
		a re-update runs them twice — but running one twice in a SINGLE update
		is a defect of this code, not of the migration, so what has run is
		recorded under /var/lib/os7/migrations inside the environment.

		That record is inside the boot environment on purpose. A rollback takes
		it away, which is precisely why C10 demands idempotence: after a
		rollback the machine has genuinely not run them, and a record that
		survived would make it claim otherwise.
	#>
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string]$Version,
		[switch]$WhatIf
	)

	$ran = @()
	$stateDir = [System.IO.Path]::Combine(
		$Root.TrimEnd('/') + $script:OS7MigrationState, $Version)

	foreach ($script in (Get-OS7Migration -Root $Root -Version $Version -Context 'chroot')) {
		$name = [System.IO.Path]::GetFileName($script)
		$stamp = [System.IO.Path]::Combine($stateDir, $name)
		if ([System.IO.File]::Exists($stamp)) {
			Write-OS7Step "migration $Version/$name has already run in this environment"
			continue
		}

		$inRoot = $script.Substring($Root.TrimEnd('/').Length)
		Write-OS7Step "migration $Version/$name"
		Invoke-OS7InRoot -Root $Root -Command @('sh', $inRoot) -WhatIf:$WhatIf | Out-Null

		if (-not $WhatIf) {
			[System.IO.Directory]::CreateDirectory($stateDir) | Out-Null
			[System.IO.File]::WriteAllText($stamp,
				"ran by Update-OS7 for $Version`n")
		}
		$ran += "$Version/$name"
	}
	return @($ran)
}


# ---------------------------------------------------------------------------
# The things the steps assert
# ---------------------------------------------------------------------------

function Get-OS7Metapackage {
	<#
	.SYNOPSIS
		Which membership metapackage this environment holds. Internal.

	.DESCRIPTION
		C6: the metapackage IS the package contract, and step 5 installs it by
		version. Which one a machine holds is recorded NOWHERE in the release
		manifest — the descriptor names os7-server and os7-desktop at the same
		version, because a release offers both and a machine is one of them.

		So dpkg is asked, inside the environment being built. The fallback is
		VARIANT_ID from os-release, which the installer writes at install time
		and which is the same fact from the other side; and if neither answers,
		this throws rather than guessing, because installing the wrong one
		swaps a desktop for a server or the reverse.
	#>
	param([Parameter(Mandatory)][string]$Root)

	foreach ($pkg in @('os7-desktop', 'os7-server')) {
		try {
			$state = Invoke-OS7InRoot -Root $Root -Command @(
				'dpkg-query', '-W', '-f=${db:Status-Status}', $pkg)
			if (([string]$state).Trim() -eq 'installed') { return $pkg }
		}
		catch { }
	}

	$variant = [string](Get-OS7OsReleaseField -Name 'VARIANT_ID' -Path ($Root + '/etc/os-release'))
	switch ($variant) {
		'gui'    { return 'os7-desktop' }
		'server' { return 'os7-server' }
	}

	throw [System.InvalidOperationException]::new(
		'this machine holds neither os7-server nor os7-desktop, and its os-release names ' +
		"no VARIANT_ID. There is no way to tell which product it is, and installing the " +
		'wrong metapackage would swap a desktop for a server. Install one by hand first, ' +
		'or see Set-OS7Mode.')
}

function Assert-OS7Branding {
	<#
	.SYNOPSIS
		The identity survived the upgrade, or say exactly why not. Internal.

	.DESCRIPTION
		C10 DELETED §4.2 step 6 — "reassert /etc/os-release, write release.json"
		— because os7-release owns both by dpkg-divert and UL10 closed.

		THAT IS TRUE OF A MACHINE THAT HOLDS os7-release, AND NO ISO INSTALLS IT
		YET. On a machine built from any current image, /usr/lib/os-release is
		base-files' conffile with hook 0075's branding written over it, and an
		`apt full-upgrade` that touches base-files puts Ubuntu's back. Assuming
		the divert would mean a machine that quietly stops calling itself OS/7
		one update after another.

		So the environment is asked which world it is in, and the branding is
		re-derived with the generator os7-release ships — never with a second
		implementation of it, which is the whole reason
		build/lib/os-release-identity.py was extracted in the first place.
	#>
	param(
		[Parameter(Mandatory)][string]$Root,
		[switch]$WhatIf
	)

	$osrel = $Root + '/etc/os-release'
	$imageId = [string](Get-OS7OsReleaseField -Name 'IMAGE_ID' -Path $osrel)
	if ($imageId -eq 'os7') { return 'intact' }

	$generator = $Root + '/usr/lib/os7/os-release-identity.py'
	if (-not [System.IO.File]::Exists($generator)) {
		throw [System.InvalidOperationException]::new(
			"the upgrade reverted /etc/os-release — IMAGE_ID is '$imageId', not 'os7' — " +
			'and this environment has no os7-release package to re-derive it. That is the ' +
			'machine no longer calling itself OS/7. Install os7-release, or roll back with ' +
			'Restore-OS7.')
	}

	Write-OS7Step 'the upgrade reverted /etc/os-release; re-deriving it'
	Invoke-OS7InRoot -Root $Root -Command @(
		'dpkg-reconfigure', 'os7-release') -WhatIf:$WhatIf | Out-Null

	if (-not $WhatIf) {
		$after = [string](Get-OS7OsReleaseField -Name 'IMAGE_ID' -Path $osrel)
		if ($after -ne 'os7') {
			throw [System.InvalidOperationException]::new(
				"re-deriving /etc/os-release left IMAGE_ID as '$after'.")
		}
	}
	return 'repaired'
}

function Assert-OS7Initramfs {
	<#
	.SYNOPSIS
		The rebuilt initramfs still carries the TPM2 token handler. Internal.

	.DESCRIPTION
		§4.2 step 7's whole point: "update-initramfs → carries the TPM2 token
		hook forward (§2.2 #3, S6)". `update-initramfs` exiting 0 says an image
		was written; it says nothing about what is in it, and BUILD-NOTES #64 is
		the record of a handler that was present, gave up silently on every boot,
		and had three checks reporting it installed.

		ONLY ON A MACHINE THAT HAD ONE. A machine with no TPM2 enrolment has no
		local-top script, and requiring one there would fail every update on
		hardware without a TPM. The question asked is therefore conditional: if
		this environment configures the handler, the produced image must carry
		it, and must run it BEFORE cryptroot — the ordering SystemSteps.cs
		already checks after an install, asked again after an update.
	#>
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)][string]$Kernel
	)

	$localTop = $Root + '/etc/initramfs-tools/scripts/local-top/os7-tpm2'
	if (-not [System.IO.File]::Exists($localTop)) {
		Write-OS7Step 'no TPM2 handler configured in this environment; nothing to carry forward'
		return $false
	}

	$listing = Invoke-OS7InRoot -Root $Root -Command @('lsinitramfs', "/boot/initrd.img-$Kernel")
	$lines = @(([string]$listing) -split "`n" | ForEach-Object { $_.Trim() })

	if ($lines -notcontains 'scripts/local-top/os7-tpm2') {
		throw [System.InvalidOperationException]::new(
			"the rebuilt initrd.img-$Kernel does not contain scripts/local-top/os7-tpm2, " +
			'and this environment is configured to use it. Nothing would try the TPM at ' +
			'boot, and the machine would ask for the passphrase with no error anywhere ' +
			'(BUILD-NOTES #64).')
	}

	# ORDER matters and is a file inside the image. os7-tpm2 has to run before
	# cryptroot or cryptroot prompts first and the token is never tried.
	# The shell line is BUILT FIRST and passed as one element. Written inline
	# with `+` inside the @(...) it is not a concatenation at all — the array
	# literal binds first and each `+` appends another element, so `sh -c` would
	# have been handed the first fragment and the rest as separate arguments.
	# BUILD-NOTES #91; found here by installer/testing/check-ps-traps.py.
	$probe = "unmkinitramfs /boot/initrd.img-$Kernel /tmp/os7-initrd >/dev/null 2>&1; " +
		'cat /tmp/os7-initrd/main/scripts/local-top/ORDER 2>/dev/null || ' +
		'cat /tmp/os7-initrd/scripts/local-top/ORDER 2>/dev/null || true'
	$order = Invoke-OS7InRoot -Root $Root -Command @('sh', '-c', $probe)
	$orderText = [string]$order
	if ($orderText) {
		$t = $orderText.IndexOf('local-top/os7-tpm2')
		$c = $orderText.IndexOf('local-top/cryptroot')
		if ($t -ge 0 -and $c -ge 0 -and $t -gt $c) {
			throw [System.InvalidOperationException]::new(
				'in the rebuilt initramfs, os7-tpm2 does not run before cryptroot. ' +
				'cryptroot would prompt for the passphrase before anything tried the TPM.')
		}
	}
	return $true
}

function Get-OS7NewestKernel {
	<#
	.SYNOPSIS
		The newest kernel in a boot environment's /boot, by VERSION. Internal.

	.DESCRIPTION
		BY VERSION AND NOT BY NAME. `Sort-Object Name -Descending` puts
		vmlinuz-7.0.0-9-generic above vmlinuz-7.0.0-31-generic, because '9' is
		greater than '3' at the fourth character. Measured 2026-08-27;
		BUILD-NOTES #89.

		This matters here more than anywhere else in the module: an update is
		exactly the operation that leaves two kernels in one environment, so it
		is the operation that turns that sort into a machine booting the older
		kernel against the newer root — §4.3's half-activated pair, reached by a
		different road, and update-grub would report nothing wrong.
	#>
	param([Parameter(Mandatory)][string]$BootDir)

	$found = @()
	if (-not [System.IO.Directory]::Exists($BootDir)) { return $null }
	foreach ($f in [System.IO.Directory]::GetFiles($BootDir, 'vmlinuz-*')) {
		$name = [System.IO.Path]::GetFileName($f)
		$release = $name.Substring('vmlinuz-'.Length)
		# 7.0.0-31-generic -> the numbers, in order, as a comparable tuple. The
		# flavour ('generic') is not part of the ordering; two flavours of one
		# version are not two versions.
		$nums = @([regex]::Matches($release, '\d+') | ForEach-Object { [int]$_.Value })
		$found += [pscustomobject]@{ Name = $name; Release = $release; Numbers = $nums }
	}
	if ($found.Count -eq 0) { return $null }

	$sorted = $found | Sort-Object -Property `
		@{ Expression = { if ($_.Numbers.Count -gt 0) { $_.Numbers[0] } else { 0 } } },
		@{ Expression = { if ($_.Numbers.Count -gt 1) { $_.Numbers[1] } else { 0 } } },
		@{ Expression = { if ($_.Numbers.Count -gt 2) { $_.Numbers[2] } else { 0 } } },
		@{ Expression = { if ($_.Numbers.Count -gt 3) { $_.Numbers[3] } else { 0 } } },
		@{ Expression = { $_.Release } }
	# BUILD-NOTES #119: `$sorted` is empty whenever the caller had no releases
	# to sort, and `$null.Release` under Set-StrictMode is a terminating error
	# rather than the $null this returns everywhere else.
	$newest = $sorted | Select-Object -Last 1
	return $(if ($newest) { $newest.Release } else { $null })
}


# ---------------------------------------------------------------------------
# The sequence
# ---------------------------------------------------------------------------

function Update-OS7 {
	<#
	.SYNOPSIS
		Apply the next curated OS/7 release into a new boot environment.

	.DESCRIPTION
		docs/RELEASE-AND-UPDATE-PLAN.md §4.2 as corrected by
		docs/CURATION-AND-DELIVERY-PLAN.md §9. The running system is not touched:
		the release is applied into a CLONE of the boot environment, and the
		machine keeps running the old one until it is rebooted. If the new one is
		wrong, Restore-OS7 goes back.

		IT DOES NOT REBOOT unless asked. Restore-OS7's reasoning applies with
		more force here: every cmdlet in this module has to work over serial and
		ssh (§6), and an unannounced reboot down a serial line is how an
		administrator loses the session that would have told them whether it
		worked.

		-WhatIf REPORTS THE PENDING RELEASE AND CHANGES NOTHING. It is not a run
		with the last step skipped: the preflight is read-only by construction,
		so -WhatIf performs it, returns the plan, and stops before the first
		snapshot.

		WHAT IT LEAVES BEHIND WHEN IT FAILS. A boot environment, inactive. An
		inactive environment does not boot and does not mount, so it is harmless
		— and it is the only evidence of what went wrong. This cmdlet names it
		on the way out rather than destroying it. `Remove-OS7BootEnvironment
		<name>` is the one command that clears it.

	.PARAMETER Version
		Which release. Without it, the newest applicable one the channel offers.

	.PARAMETER Channel
		Which channel to read. Defaults to this machine's.

	.PARAMETER Source
		A repository URI, overriding the machine's — a mirror, or an offline
		bundle copied off a stick.

	.PARAMETER Stage
		Build the new environment and stop before activating it (§6). Everything
		through step 8 runs; the machine still boots what it boots. Activate it
		later with Set-OS7BootEnvironment, or roll the whole thing away with
		Remove-OS7BootEnvironment.

	.PARAMETER Reboot
		Reboot when it is done. Step 10, and never the default.

	.PARAMETER Keep
		How many boot environments to leave behind, counting the new one.
		Defaults to two — the new one and the one it replaced, so Restore-OS7
		always has a target (UL9). Older complete environments are removed.

	.PARAMETER AllowDevelopment
		Apply a release signed by a development key. C7a — where a release
		signing key lives — is open, so today every key is a development key and
		this switch is required for every real run. It is not a convenience: it
		is how a machine says out loud that it is taking something unpublished.

	.PARAMETER Force
		Proceed although the running system has drifted from its manifest.
		Drift means somebody has run apt by hand (§5), so the release being
		applied is not being applied to the system the manifest describes.

	.EXAMPLE
		Update-OS7 -WhatIf

	.EXAMPLE
		Update-OS7 -Stage -AllowDevelopment

	.EXAMPLE
		Update-OS7 -Version 1.0.1.412 -Reboot
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('OS7.Update')]
	param(
		[string]$Version,
		[string]$Channel,
		[string]$Source,
		[switch]$Stage,
		[switch]$Reboot,
		[int]$Keep = $script:OS7KeepBootEnvironments,
		[switch]$AllowDevelopment,
		[switch]$Force
	)

	if ($Keep -lt 1) {
		throw [ArgumentException]::new(
			'-Keep must be at least 1: the environment being built is one of them.', 'Keep')
	}

	# ---- 0. Preflight. Read-only, and every refusal happens here ------------
	#
	# ONE LOCK FOR THE MACHINE. Two updates cloning the same environment produce
	# two environments from one origin, both claiming the same release, and the
	# second activation silently wins. The idiom is the backup feature's.
	$lock = $null
	try {
		$lock = [System.IO.File]::Open($script:OS7UpdateLock,
			[System.IO.FileMode]::OpenOrCreate,
			[System.IO.FileAccess]::ReadWrite,
			[System.IO.FileShare]::None)
	}
	catch [System.IO.IOException] {
		# ONLY a sharing violation means somebody else holds it. A read-only
		# /run, a full tmpfs or a permission problem are all IOException's
		# neighbours and none of them is another update — reporting them as one
		# sends an operator looking for a process that does not exist.
		throw [System.InvalidOperationException]::new(
			'another update holds ' + $script:OS7UpdateLock + '. Two updates cloning one ' +
			'environment produce two environments claiming one release.')
	}
	catch {
		throw [System.InvalidOperationException]::new(
			"cannot take the update lock at $($script:OS7UpdateLock): $($_.Exception.Message)")
	}

	try {
		$here = Get-OS7Version
		if (-not $here.Known) {
			throw [System.InvalidOperationException]::new(
				"this machine has no release manifest at $($here.ManifestPath), so there is " +
				'no version to update FROM. It is not an OS/7 machine, or its os7-release ' +
				'is missing.')
		}
		$from = [string]$here.FullVersion

		$offered = @(Get-OS7Release -Available -Channel $Channel -Source $Source)
		if ($offered.Count -eq 0) {
			throw [System.InvalidOperationException]::new(
				'the channel offers no releases at all.')
		}

		if ($Version) {
			# One version can be TWO entries when one repository serves both
			# architectures (RELEASE-PROCESS §7.3). The machine's own comes
			# first; the foreign one is kept as a fallback so the refusal
			# below can name the real reason instead of "no such release".
			$target = $offered |
				Where-Object { $_.Version -eq $Version -and -not $_.ForeignArchitecture } |
				Select-Object -First 1
			if (-not $target) {
				$target = $offered | Where-Object Version -eq $Version | Select-Object -First 1
			}
			if (-not $target) {
				throw [System.InvalidOperationException]::new(
					"the channel offers no release $Version. Get-OS7Release -Available lists " +
					'what it does offer.')
			}
		}
		else {
			# Newest APPLICABLE, sorted by version and not by the order the index
			# happens to list them in.
			$target = $offered | Where-Object Applicable |
				Sort-Object -Property @{ Expression = { [version]$_.Version } } |
				Select-Object -Last 1
			if (-not $target) {
				Write-OS7Step "nothing to do: $from is the newest release this channel offers"
				return [pscustomobject]@{
					PSTypeName = 'OS7.Update'
					From = $from; To = $from; Applied = $false
					BootEnvironment = $null; Staged = $false; Activated = $false
					Migrations = @(); Removed = @()
					Reason = 'this machine is already on the newest release the channel offers'
				}
			}
		}

		$to = [string]$target.Version

		# C12: a generation is an explicit, separate operation. The suite name
		# already makes it impossible by apt; refusing here says why, which apt
		# would not.
		if ($target.CrossesMajor) {
			throw [System.InvalidOperationException]::new(
				"$to is a different OS/7 generation from $from. A generation upgrade is a " +
				'separate, explicit operation and this train refuses to attempt one (C12).')
		}
		if (-not $target.Newer) {
			throw [System.InvalidOperationException]::new(
				"$to is not newer than $from. This train moves forward only; to go back, " +
				'use Restore-OS7.')
		}

		# One repository URL may serve both architectures (RELEASE-PROCESS.md
		# §7.3). An explicit -Version reaches here past Applicable, so the
		# mismatch is its own refusal — without it apt fails late, about
		# unsatisfiable packages, on a machine that was told the release was
		# for it.
		if ($target.ForeignArchitecture) {
			throw [System.InvalidOperationException]::new(
				"$to is built for $($target.Architecture) and this machine is " +
				"$((Get-OS7Version).Architecture). A release moves a machine within its " +
				'own architecture; this is a different product.')
		}

		# §7: a hotfix overlays exactly the base release it names. Applying it
		# to any other machine produces a system no descriptor describes — the
		# overlay packages assume the base's package set, and the version
		# number x.y.z.N+1 would claim a state the machine never held. An
		# explicit -Version reaches here past Applicable, which is why this is
		# its own refusal and not a filter.
		if ($target.Hotfix -and
				(Compare-OS7Version -Left $target.HotfixBase -Right $from) -ne 0) {
			throw [System.InvalidOperationException]::new(
				"$to is a hotfix of $($target.HotfixBase) and this machine runs $from. " +
				"A hotfix overlays exactly the release it names (§7); update to " +
				"$($target.HotfixBase) first, then apply the hotfix.")
		}

		# C7a is open. Every key that exists today is a development key, so this
		# refusal fires on every real run — which is the honest state and not an
		# inconvenience to be smoothed away.
		if ($target.Development -and -not $AllowDevelopment) {
			throw [System.InvalidOperationException]::new(
				"$to is signed by a DEVELOPMENT key ($($target.SigningKey)), which means it " +
				'is not a published release. Pass -AllowDevelopment to apply it anyway.')
		}

		# §5: apt is still on the machine and somebody eventually types it. A
		# release applied to a drifted system is not the system its manifest
		# describes, and the resulting version number would be a lie.
		$drift = $null
		try { $drift = (Get-OS7Version -CheckDrift).Drift } catch { }
		if ($drift -and $drift.State -eq 'Drifted' -and -not $Force) {
			throw [System.InvalidOperationException]::new(
				"this machine has drifted from its manifest — packages have changed outside " +
				'the update train (§5). Applying a release on top of that produces a version ' +
				'number that describes nothing. Get-OS7Version -CheckDrift says what moved; ' +
				'-Force proceeds anyway.')
		}

		$beName = New-OS7BootEnvironmentName -Release $to
		$plan = [pscustomobject]@{
			PSTypeName      = 'OS7.Update'
			From            = $from
			To              = $to
			Applied         = $false
			BootEnvironment = $beName
			Staged          = [bool]$Stage
			Activated       = $false
			Migrations      = @()
			Removed         = @()
			Reason          = $null
		}

		# -WhatIf ENDS HERE, having changed nothing. Everything above is a read.
		if (-not $PSCmdlet.ShouldProcess("$from -> $to",
				"build boot environment $beName and apply the release into it")) {
			$plan.Reason = 'reported only; nothing was changed'
			return $plan
		}

		Write-OS7Step "update $from -> $to into $beName"
		Write-OS7UpdateLog ("START $from -> $to  environment=$beName " +
			"stage=$([bool]$Stage) keep=$Keep " +
			"development=$($target.Development) source=$(Get-OS7UpdateSource -Source $Source)")

		# ---- 1. The deliberate-rollback net -------------------------------
		#
		# §4.2 step 1 snapshots three things, and New-OS7BootEnvironment does
		# two of them. rpool/DATA is this cmdlet's, and it is what §4.4 means by
		# "The @pre-<version> snapshot in step 1 therefore covers the rpool/DATA
		# datasets too, so an operator CAN roll one back deliberately and
		# individually. Automatically, never."
		#
		# NAMED AFTER THE ENVIRONMENT, not "@pre-<version>" as §4.2 writes it.
		# One convention for the machine: New-OS7BootEnvironment already names
		# its snapshots after the environment they were taken for, so
		# `zfs list -t snapshot` reads as one story instead of two.
		Import-OS7ZfsLayer
		if (@(Get-ZfsDataset -Name 'rpool/DATA' -Type Filesystem -ErrorAction SilentlyContinue)) {
			New-ZfsSnapshot -Name 'rpool/DATA' -SnapshotName $beName -Recurse -Confirm:$false | Out-Null
			# No -Recurse: Get-ZfsSnapshot recurses by DEFAULT — "asking for the
			# snapshots of rpool/DATA almost always means the ones below it as
			# well", which is the opposite of what listing a filesystem means.
			$net = @(Get-ZfsSnapshot -Name 'rpool/DATA' -ErrorAction SilentlyContinue |
				Where-Object { $_.Name -like "*@$beName" })
			if ($net.Count -eq 0) {
				throw [System.InvalidOperationException]::new(
					"the rpool/DATA snapshot @$beName was taken and ZFS does not report it. " +
					'Without it a rollback cannot recover data an update migrated (§4.4).')
			}
			Write-OS7Step "rollback net: $($net.Count) rpool/DATA snapshot(s) @$beName"
		}
		else {
			Write-OS7Step 'no rpool/DATA on this machine; no rollback net to take'
		}

		# ---- 2. Clone the pair --------------------------------------------
		#
		# The primitive checks its own work: every clone re-read for canmount and
		# the environment's root for mountpoint=/. It leaves the pair INERT.
		#
		# -From IS PASSED EXPLICITLY, resolved here with -First 1. The primitive's
		# own default is `$all | Where-Object Active` with no -First, and Active
		# is ZFS's `mounted` — so on a machine where anything has a boot
		# environment mounted anywhere, that default yields TWO objects, which a
		# [string] parameter silently coerces to "os7_a os7_b". BUILD-NOTES #65's
		# shape. This cmdlet is the one that mounts environments, so it is the
		# one that must not rely on that default.
		# $fromBe AND NOT $source — BUILD-NOTES #65, walked into by code that
		# cites #65 four lines above it.
		#
		# This cmdlet has a `-Source` parameter. PowerShell variable names are
		# case-insensitive, so `$source = <object>` IS an assignment to that
		# [string] parameter, and the object is silently coerced to its type
		# name. `-not $source` is then false — the string is non-empty — and the
		# next line asks a String for a `.Name`, which produces
		#
		#     The property 'Name' cannot be found on this object.
		#
		# naming no variable and no parameter. Found 2026-08-27 by
		# check-update-logic.py in three seconds, which is the whole argument
		# for that file existing.
		$fromBe = @(Get-OS7BootEnvironment) |
			Where-Object { (Test-OS7IsRunning $_) -and $_.Complete } | Select-Object -First 1
		if (-not $fromBe) {
			throw [System.InvalidOperationException]::new(
				'no complete boot environment is mounted, so there is nothing to clone from.')
		}
		$be = New-OS7BootEnvironment -Name $beName -From $fromBe.Name -Release $to -Confirm:$false
		if (-not $be) {
			throw [System.InvalidOperationException]::new(
				"New-OS7BootEnvironment returned nothing for $beName.")
		}

		$root = $script:OS7UpdateRoot
		$stillMounted = @()
		# SET BEFORE THE CALL, NOT AFTER IT. Mount-OS7UpdateRoot mounts a dozen
		# things and can throw on any of them, so "it returned" is the wrong
		# question — the question is whether anything might be mounted, and from
		# the first line of that function the answer is yes. Setting this
		# afterwards leaked five mounts under /run/os7-update on the first run
		# that failed halfway, and left the machine with a second boot
		# environment reporting Active.
		$assembled = $true
		try {
			# ---- 3. Assemble ----------------------------------------------
			#
			# The assertion is over what the assembler ACTUALLY MOUNTED, not
			# over a list this code composed from what it expected. Those are
			# different questions, and the second one cannot see a dataset the
			# layout gained.
			$expected = @(Mount-OS7UpdateRoot -Name $beName -Root $root)
			if ($expected.Count -lt 3) {
				throw [System.InvalidOperationException]::new(
					"assembling $beName produced only $($expected.Count) mount(s). A boot " +
					'environment is at least its root, its /boot and /dev.')
			}
			Assert-OS7UpdateRootAssembled -Root $root -Expected $expected

			# ---- 4. Point apt at BOTH repositories ------------------------
			#
			# C10 puts "point at both repos" in step 5's cell; it is step 4's
			# work and C10 did not renumber, so it lives here.
			$d = $target.Descriptor
			$base = Get-OS7ManifestField $d 'base'
			$archiveBase = [string](Get-OS7ManifestField $base 'archive_base')
			$snapshot    = [string](Get-OS7ManifestField $base 'archive_snapshot')
			$codename    = [string](Get-OS7ManifestField $base 'distribution')
			if (-not $codename -or $codename -eq 'ubuntu') {
				$codename = [string](Get-OS7ReleaseConfField -Name 'OS7_DISTRIBUTION')
			}
			if (-not $archiveBase -or -not $snapshot -or -not $codename) {
				throw [System.InvalidOperationException]::new(
					"the descriptor for $to does not name an archive to update from " +
					"(base: $archiveBase / $snapshot / $codename).")
			}

			$ubuntu = @(
				'# Written by Update-OS7. The archive is PINNED: a version number is only'
				'# honest if the archive is (RELEASE-AND-UPDATE-PLAN §3.1).'
				'Types: deb'
				"URIs: $archiveBase/$snapshot"
				"Suites: $codename $codename-updates $codename-security"
				'Components: main restricted universe multiverse'
				'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'
			) -join "`n"
			# The directory FIRST. /etc is inside the boot environment, so it
			# has whatever the running system had — but a machine using the
			# single-file sources.list has no sources.list.d, and the write
			# would fail on a path rather than on anything about apt.
			[System.IO.Directory]::CreateDirectory("$root/etc/apt/sources.list.d") | Out-Null
			[System.IO.File]::WriteAllText("$root/etc/apt/sources.list.d/ubuntu.sources", $ubuntu + "`n")
			# The single-file form takes precedence in confusing ways when both
			# exist; a machine being updated should have exactly one answer.
			if ([System.IO.File]::Exists("$root/etc/apt/sources.list")) {
				[System.IO.File]::Move("$root/etc/apt/sources.list",
					"$root/etc/apt/sources.list.os7-update", $true)
			}

			# The OS/7 suite, pointed at the SAME repository this release was
			# read from — not at whatever the environment happened to inherit.
			# A file:// URI resolves against the CHROOT, so a local repository
			# has to be bound in before apt can see it.
			$repoUri = Get-OS7UpdateSource -Source $Source
			if ($repoUri.StartsWith('file://')) {
				$localRepo = $repoUri.Substring('file://'.Length)
				[System.IO.Directory]::CreateDirectory($root + $localRepo) | Out-Null
				Invoke-OS7Native -Command 'mount' -Arguments @(
					'--bind', $localRepo, ($root + $localRepo)) | Out-Null
				$expected += ($root + $localRepo)
			}
			$suite = [string]$target.Suite
			if (-not $suite) { $suite = Get-OS7ReleaseConfField -Name 'OS7_SUITE' }
			$arch = ([string](Invoke-OS7Native -Command 'dpkg' -Arguments @('--print-architecture'))).Trim()
			# WHAT WAS THERE BEFORE, so it can be put back. A `-Source` given
			# for one run — a mirror, a stick, a harness — must not become the
			# machine's permanent channel because the update happened to write
			# it in. $null means the environment had no OS/7 source at all,
			# which is the state a machine installed from today's ISO is in.
			$os7SrcPath = "$root$($script:OS7AptSource)"
			$os7SrcBefore = if ([System.IO.File]::Exists($os7SrcPath)) {
				[System.IO.File]::ReadAllText($os7SrcPath)
			} else { $null }

			$os7src = @(
				'# Written by Update-OS7 for the duration of this update.'
				'Types: deb'
				"URIs: $repoUri"
				"Suites: $suite"
				'Components: main'
				"Architectures: $arch"
				"Signed-By: $($script:OS7Keyring)"
				'Enabled: yes'
			) -join "`n"
			[System.IO.Directory]::CreateDirectory("$root/etc/apt/sources.list.d") | Out-Null
			[System.IO.File]::WriteAllText("$root$($script:OS7AptSource)", $os7src + "`n")

			# ---- 5. apt: install, upgrade, autoremove — in that order ------
			#
			# THE TARGET VERSION IS PINNED ACROSS full-upgrade, and without this
			# -Version can only ever name the newest release in the suite.
			# `apt install os7-server=1.0.1.0` marks it manually installed at
			# that version; it does not HOLD it, and the OS/7 suite is one suite
			# per Major with an accumulating pool — so the very next
			# `full-upgrade` carries it to whatever is newest. C11 says any
			# version may move to any LATER version within one Major, and the
			# operator naming one is exactly the case that would have broken.
			#
			# Every os7-* package, because a release moves as one: pinning the
			# metapackage alone would let its versioned dependencies move out
			# from under it and make the transaction unsatisfiable.
			$pinFile = "$root/etc/apt/preferences.d/os7-update.pref"
			[System.IO.Directory]::CreateDirectory("$root/etc/apt/preferences.d") | Out-Null
			[System.IO.File]::WriteAllText($pinFile, @(
				'# Written by Update-OS7 for the duration of this update, and removed'
				'# again afterwards. It is what makes -Version mean a version.'
				'Package: os7-*'
				"Pin: version $to"
				'Pin-Priority: 1001'
			) -join "`n")

			$apt = @('env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', '-y', '-o',
				'Dpkg::Options::=--force-confold')
			Invoke-OS7InRoot -Root $root -Command @('env', 'DEBIAN_FRONTEND=noninteractive',
				'apt-get', '-y', 'update') | Out-Null

			# ASK apt WHAT IT FOUND. `apt-get update` exits 0 with every index
			# failed, so its exit code says nothing at all about whether the OS/7
			# suite is reachable from inside this chroot.
			$metapackage = Get-OS7Metapackage -Root $root
			$policy = [string](Invoke-OS7InRoot -Root $root -Command @('apt-cache', 'policy', $metapackage))
			if ($policy -notmatch [regex]::Escape($to)) {
				throw [System.InvalidOperationException]::new(
					"inside the new environment, apt does not offer $metapackage=$to." +
					"`n$policy`nThe OS/7 suite is not reachable from the chroot, or this " +
					'release does not contain that metapackage.')
			}

			Write-OS7Step "installing $metapackage=$to"
			Write-OS7UpdateLog "apt: install $metapackage=$to, full-upgrade, autoremove"
			Invoke-OS7InRoot -Root $root -Command ($apt + @('install', "$metapackage=$to")) | Out-Null
			Invoke-OS7InRoot -Root $root -Command ($apt + @('full-upgrade')) | Out-Null
			# LAST, and the order is C10's. autoremove before install would take
			# the product out: the metapackage is what marks the set as wanted.
			Invoke-OS7InRoot -Root $root -Command ($apt + @('autoremove')) | Out-Null

			$got = ([string](Invoke-OS7InRoot -Root $root -Command @(
				'dpkg-query', '-W', '-f=${Version}', $metapackage))).Trim()
			if ($got -ne $to) {
				throw [System.InvalidOperationException]::new(
					"after the upgrade $metapackage is $got, not $to. apt exited 0 and " +
					'installed something else — a pin, or a dependency that could not be ' +
					'satisfied at the requested version.')
			}

			# ---- 6. deleted by C10 — but verified, see the function --------
			$branding = Assert-OS7Branding -Root $root

			# ---- 6'. Migrations -------------------------------------------
			#
			# EVERY RELEASE BETWEEN the one this machine was on and the one being
			# applied, in order. C11(c) makes 1.0.0 -> 1.0.7 one operation, and
			# says "the only sequencing is the migrations, which are keyed by the
			# FROM version and applied in order" — so a release declares what
			# changed in IT, and a jump runs each of them rather than requiring
			# every release to carry a migration for every older version.
			$ran = @()
			$between = @($offered |
				Where-Object { (Compare-OS7Version -Left $_.Version -Right $from) -gt 0 -and
					(Compare-OS7Version -Left $_.Version -Right $to) -le 0 } |
				Sort-Object -Property @{ Expression = { [version]$_.Version } })
			foreach ($step in $between) {
				$ran += @(Invoke-OS7Migration -Root $root -Version ([string]$step.Version))
			}
			# What could not run here, said out loud rather than skipped in
			# silence. BUILD-NOTES #69: a migration that must observe the real
			# boot cannot run in a chroot at all.
			$pending = @()
			foreach ($step in $between) {
				$pending += @(Get-OS7Migration -Root $root -Version ([string]$step.Version) -Context 'firstboot')
			}
			if ($pending.Count -gt 0) {
				$pendingFile = $root + $script:OS7MigrationState + '/pending'
				[System.IO.Directory]::CreateDirectory(
					[System.IO.Path]::GetDirectoryName($pendingFile)) | Out-Null
				[System.IO.File]::WriteAllText($pendingFile,
					(($pending | ForEach-Object { $_.Substring($root.Length) }) -join "`n") + "`n")
				Write-OS7Step ("$($pending.Count) migration(s) must run on the target's FIRST " +
					'BOOT and have been recorded, not run')
			}

			# ---- 7. The initramfs -----------------------------------------
			$kernel = Get-OS7NewestKernel -BootDir ($root + '/boot')
			if (-not $kernel) {
				throw [System.InvalidOperationException]::new(
					"the new environment has no kernel in /boot. It cannot boot.")
			}
			Write-OS7UpdateLog ("migrations: " + $(if ($ran.Count) { $ran -join ' ' } else { 'none' }))
			Write-OS7Step "rebuilding the initramfs for $kernel"
			Invoke-OS7InRoot -Root $root -Command @('update-initramfs', '-u', '-k', 'all') | Out-Null
			if (-not [System.IO.File]::Exists("$root/boot/initrd.img-$kernel")) {
				throw [System.InvalidOperationException]::new(
					"update-initramfs exited 0 and there is no /boot/initrd.img-$kernel.")
			}
			$tpm = Assert-OS7Initramfs -Root $root -Kernel $kernel

			# ---- 8. The menu, inside the environment ----------------------
			Invoke-OS7InRoot -Root $root -Command @('update-grub') | Out-Null

			# ---- what belonged to this run, taken back out ----------------
			#
			# THE PIN AND THE SOURCE ARE THIS RUN'S, NOT THE MACHINE'S. Both
			# were written into the environment that is about to be booted, and
			# leaving them there ships them: the pin would freeze every future
			# `apt` at this version, and a `-Source` handed in for one run — a
			# stick, a mirror, a harness — would silently become the channel the
			# machine follows for ever after.
			#
			# The Ubuntu source STAYS, deliberately. It names the archive
			# snapshot of the release just applied, which is what this machine's
			# pin now is (§3.1). That one is not a leftover; it is the result.
			[System.IO.File]::Delete($pinFile)

			# The new os7-release, if the release carried one, has already
			# rewritten this file during step 5 — dpkg owns that path. Restoring
			# then would put a stale file over a package's own. So it is only
			# put back when what is there is still the file THIS RUN wrote.
			if ([System.IO.File]::Exists($os7SrcPath) -and
					[System.IO.File]::ReadAllText($os7SrcPath) -eq ($os7src + "`n")) {
				if ($null -eq $os7SrcBefore) {
					[System.IO.File]::Delete($os7SrcPath)
					Write-OS7Step 'the OS/7 apt source was this run only; removed from the environment'
				}
				else {
					# WITH THE TARGET'S SUITE, not the one the machine followed
					# before. The environment being written IS the target
					# release: a 1.0.x machine moving to 1.1.0 must wake up on
					# `os7-1.1`, and the file being put back is a conffile
					# Set-OS7UpdateChannel wrote with `os7-1.0` — kept by
					# --force-confold across every later upgrade, so nothing
					# downstream would ever correct it (RELEASE-PROCESS.md
					# §7.2). Rewritten only when the suites differ, so an
					# ordinary same-suite update restores the file byte for
					# byte.
					$restored = $os7SrcBefore
					if ($suite -and $restored -match '(?m)^Suites:\s*(\S+)\s*$' -and
							$Matches[1] -ne $suite) {
						$restored = $restored -replace '(?m)^Suites:\s*\S+\s*$', "Suites: $suite"
						Write-OS7Step ("the machine's OS/7 apt source moves to suite " +
							"$suite with this release")
					}
					[System.IO.File]::WriteAllText($os7SrcPath, $restored)
					Write-OS7Step "restored the environment's own OS/7 apt source"
				}
			}
		}
		finally {
			# THE CLONE MUST BE UNMOUNTED BEFORE ANY BE CMDLET IS CALLED.
			# Get-OS7BootEnvironment's Active is ZFS's `mounted` property, which
			# is "mounted anywhere" — so while this is assembled, TWO
			# environments report Active, and Set-OS7BootEnvironment picks its
			# menu template from the first of them.
			if ($assembled) {
				# @(...) AROUND THE CALL. A PowerShell function returning an
				# EMPTY array returns $null to its caller — the array is
				# unrolled on the way out and nothing is left — so `$left.Count`
				# throws "The property 'Count' cannot be found on this object"
				# under StrictMode, from a finally block, replacing whatever
				# real failure brought it there.
				$stillMounted = @(Dismount-OS7UpdateRoot -Root $root)
			}
		}

		# AND IT ACTUALLY REFUSES. This used to write "refusing to go further"
		# from inside the finally block and then go further — the message was
		# the whole of the refusal. It is out of the finally now because a
		# `throw` there would replace whatever real failure brought it, and it
		# is a `throw` because the state it describes is the one that makes the
		# next two steps do the wrong thing quietly: while the clone is mounted,
		# Get-OS7BootEnvironment reports TWO environments Active — its Active is
		# ZFS's `mounted`, which is "mounted anywhere" — and
		# Set-OS7BootEnvironment picks its menu template from the first of them.
		if ($stillMounted.Count -gt 0) {
			throw [System.InvalidOperationException]::new(
				"the new environment is still mounted at:`n  " +
				($stillMounted -join "`n  ") +
				"`nActivating it now would have the boot-environment cmdlets see two " +
				"running systems. $beName is built and inactive; unmount those paths and " +
				"activate it with Set-OS7BootEnvironment -Name $beName.")
		}

		$plan.Migrations = @($ran)
		$plan.Applied = $true

		# ---- 9. Activate, and prune ---------------------------------------
		if ($Stage) {
			$plan.Reason = "staged: $beName is built and inactive. Activate it with " +
				"Set-OS7BootEnvironment -Name $beName, or remove it with " +
				"Remove-OS7BootEnvironment -Name $beName."
			Write-OS7Step $plan.Reason
			Write-OS7UpdateLog "STAGED $to into $beName; not activated"
			return $plan
		}

		Set-OS7BootEnvironment -Name $beName -Confirm:$false | Out-Null
		$plan.Activated = $true

		# WHAT THIS UPDATE CAME FROM, recorded as a fact — because the promote
		# below ROTATES the ZFS ancestry: after it the new environment's origin
		# is '-', the OLD one's origin points AT the new, and even sibling
		# clones' origins move (all measured, BUILD-NOTES #107). Restore-OS7
		# reads this property first; without it, "previous" degraded to an age
		# heuristic that once rolled a machine back onto an experiment's
		# leftover clone instead of the release the update was applied to.
		try {
			Set-ZfsProperty -Name "$($script:OS7RootParent)/$beName" `
				-PropertyName 'org.os7:previous' -Value $fromBe.Name -Confirm:$false | Out-Null
		}
		catch {
			Write-OS7Step "note: could not record the previous environment: $($_.Exception.Message)"
		}

		# ---- UL9's retention ----------------------------------------------
		#
		# A boot environment per release with no prune rule is how these systems
		# fail in practice.
		#
		# THE NEW ENVIRONMENT IS PROMOTED FIRST, AND WITHOUT THAT NOTHING CAN
		# EVER BE REMOVED. A boot environment is a `zfs clone` of a snapshot of
		# the one before it, and `zfs destroy` refuses a dataset whose snapshot
		# has a live clone:
		#
		#     os7_a  --snapshot @os7_b-->  os7_b (clone)
		#
		# so destroying os7_a fails for as long as os7_b exists. `zfs promote`
		# reverses it: the clone takes ownership of the shared history and the
		# ORIGINAL becomes the dependent one. That is what beadm and zsys do and
		# it is why they can prune at all.
		#
		# BOTH HALVES, because a boot environment is two datasets in two pools
		# (§4.3) and promoting one of them would leave the other undestroyable —
		# a half-pruned pair, which is the same class of state UL8 is about.
		foreach ($half in @("$($script:OS7RootParent)/$beName",
				"$($script:OS7BootParent)/$beName")) {
			try { Convert-ZfsClone -Name $half -Confirm:$false | Out-Null }
			catch {
				Write-OS7Step "could not promote $half`: $($_.Exception.Message)"
			}
		}

		$known = @(Get-OS7BootEnvironment)
		# Never the running one and never the one the menu names — after an
		# activation and before the reboot those are two DIFFERENT environments,
		# and destroying either produces a machine that does not start (the
		# second one silently, at the next boot).
		$pinned = @($known | Where-Object { (Test-OS7IsRunning $_) -or $_.Menu -or $_.Active } |
			ForEach-Object { $_.Name })

		# $Keep COUNTS EVERY ENVIRONMENT, including the pinned ones. The first
		# version subtracted one for the new environment and then applied that
		# to a list the pinned ones had already been removed from, so `-Keep 2`
		# left three. Sort newest first, walk the whole list, and stop removing
		# once $Keep survivors have been counted.
		$ordered = @($known | Sort-Object Created -Descending)
		$survivors = 0
		$removed = @()
		foreach ($be in $ordered) {
			if ($be.Name -in $pinned) { $survivors++; continue }
			if ($survivors -lt $Keep) { $survivors++; continue }
			try {
				Remove-OS7BootEnvironment -Name $be.Name -Confirm:$false | Out-Null
				# The rollback net taken for THAT environment goes with it.
				# Otherwise every update leaves a recursive rpool/DATA snapshot
				# that nothing ever removes, and the pool fills with the
				# safety net rather than with the environments.
				foreach ($snap in @(Get-ZfsSnapshot -Name 'rpool/DATA' -ErrorAction SilentlyContinue |
						Where-Object { $_.Name -like "*@$($be.Name)" })) {
					try { Remove-ZfsSnapshot -Name $snap.Name -Confirm:$false | Out-Null }
					catch { Write-OS7Step "could not remove $($snap.Name)" }
				}
				$removed += $be.Name
			}
			catch {
				# Said, not swallowed. A prune that cannot run is a pool that
				# fills, and UL9 is the record of that being how these systems
				# fail — so it has to be visible in the log an operator reads
				# after the fact, not only on a console nobody was watching.
				Write-OS7Step "could not remove $($be.Name)`: $($_.Exception.Message)"
				Write-OS7UpdateLog "PRUNE FAILED $($be.Name): $($_.Exception.Message.Replace("`n", ' '))"
				$survivors++
			}
		}
		$plan.Removed = @($removed)
		if ($removed.Count -gt 0) {
			Write-OS7Step ("pruned to $Keep boot environment(s); removed " + ($removed -join ' '))
			Write-OS7UpdateLog ("pruned: " + ($removed -join ' '))
		}

		# ---- 10. Reboot, only if asked ------------------------------------
		$plan.Reason = "this machine still runs $from until it is rebooted"
		if ($Reboot) {
			Write-OS7UpdateLog "DONE $from -> $to, activated $beName, rebooting"
			Write-OS7Step "rebooting into $beName"
			Invoke-OS7Native -Command 'systemctl' -Arguments @('reboot') | Out-Null
			$plan.Reason = "rebooting into $beName"
		}
		else {
			Write-OS7UpdateLog "DONE $from -> $to, activated $beName, reboot pending"
			Write-OS7Step $plan.Reason
		}
		return $plan
	}
	catch {
		# WHAT WAS LEFT BEHIND, SAID ON THE WAY OUT — the cmdlet's own help
		# promises this and, until the review of 2026-08-27, nothing did it.
		#
		# The environment is left rather than destroyed. It is INACTIVE by
		# construction (New-OS7BootEnvironment leaves every dataset noauto and
		# Set-OS7BootEnvironment has not run), so it does not boot and does not
		# mount, and it is the only evidence of what went wrong. Destroying it
		# would be tidying away the thing somebody needs to look at.
		#
		# $beName may not exist yet: a preflight refusal happens before it is
		# computed, and there is nothing to name then.
		$half = if (Get-Variable -Name beName -Scope 0 -ErrorAction SilentlyContinue) { $beName } else { $null }
		Write-OS7UpdateLog ("FAILED " + $_.Exception.Message.Replace("`n", ' ') +
			$(if ($half) { "  left behind: $half" } else { '' }))
		# FORENSICS FOR #104's open half: both end-to-end failures so far lost
		# a RUNNING-SYSTEM mount (/boot/efi once, /boot once) somewhere around
		# the dismount, at a point that moved between runs. Whatever the
		# mechanism turns out to be, the next failure should carry the mount
		# state out with it instead of leaving it to a later boot to infer.
		foreach ($probe in @('/boot', '/boot/efi')) {
			$state = try {
				[string](Invoke-OS7Native -Command 'findmnt' -Arguments @('-no', 'SOURCE,FSTYPE', $probe))
			} catch { 'NOT MOUNTED' }
			Write-OS7UpdateLog "FAILED-state ${probe}: $state"
		}
		if ($half) {
			# "Still boots what it booted" is a CLAIM, so ask the machine
			# rather than assert it: an activation can fail AFTER its point of
			# no return (the ESP stub rewrite), and then the new environment is
			# what this machine boots, failure or not. The Menu property is
			# read from the stub itself.
			$switched = $false
			try { $switched = [bool](Get-OS7BootEnvironment -Name $half).Menu } catch { }
			if ($switched) {
				Write-OS7Step ("the update failed AFTER activation's point of no return: " +
					"the ESP already names $half and this machine will boot it. Read " +
					$script:OS7UpdateLog + ' before rebooting.')
			}
			else {
				Write-OS7Step ("the update failed. $half is built, INACTIVE and left in place " +
					"as the evidence; this machine still boots what it booted. Clear it with " +
					"Remove-OS7BootEnvironment -Name $half, and read " +
					$script:OS7UpdateLog + '.')
			}
		}
		throw
	}
	finally {
		if ($lock) { $lock.Dispose() }
	}
}


# =============================================================================
# The self-test
#
# THE SAME TWO TIERS AS Test-ZfsModule AND Test-OS7Backup, for the same reason:
# there is no Pester in the image, adding one would mean a new pinned component
# for test code only, and a test only a developer can run is a test that stops
# being run.
#
#   tier 1  here. The decisions this file makes, checked against fabricated
#           trees and recorded facts. No ZFS, no repository, no root, no VM,
#           about a second.
#   tier 2  installer/testing/check-update-logic.py — the cmdlets against fake
#           zfs, apt and chroot, in a container.
#   tier 3  installer/testing/run-s5.py on a booted machine. That is the gate,
#           and nothing here replaces it.
#
# WHAT TIER 1 CAN SEE: every ordering, precedence and refusal this file encodes.
# WHAT IT CANNOT: whether apt, dpkg or update-initramfs then behave as assumed.
# =============================================================================

function Test-OS7Update {
	<#
	.SYNOPSIS
		Check the update train's decisions. No ZFS, no repository, no VM.

	.EXAMPLE
		pwsh -c 'Import-Module ./powershell/OS7/OS7.psd1 -Force; Test-OS7Update'
	#>
	[CmdletBinding()]
	param()

	$pass = 0
	$fail = [System.Collections.Generic.List[string]]::new()

	function ok($name, $cond, $detail = '') {
		if ($cond) { [Console]::Error.WriteLine("  PASS  $name"); return $true }
		[Console]::Error.WriteLine("  FAIL  $name $detail")
		return $false
	}
	function check($name, $cond, $detail = '') {
		if (ok $name $cond $detail) { $script:__os7UpdPass++ } else { $script:__os7UpdFail.Add($name) }
	}
	$script:__os7UpdPass = 0
	$script:__os7UpdFail = $fail

	[Console]::Error.WriteLine('OS/7 Update self-test')

	$tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
		'os7-update-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
	[System.IO.Directory]::CreateDirectory($tmp) | Out-Null
	try {
		# -------------------------------------------------------------------
		# 1. VERSIONS ARE COMPARED AS VERSIONS.
		#
		# This is first because it is the mistake this whole file is careful
		# about, and because the same mistake is live elsewhere in the module:
		# "1.0.0.9" sorts ABOVE "1.0.0.31" as a string. Every ordering decision
		# an update makes — which release is newest, which migrations lie
		# between two versions, which kernel the menu names — is wrong in the
		# same direction if this is wrong.
		# -------------------------------------------------------------------
		check 'a four-field version compares numerically, not lexically' `
			((Compare-OS7Version -Left '1.0.0.31' -Right '1.0.0.9') -gt 0) `
			'1.0.0.31 must be greater than 1.0.0.9'
		check 'the string comparison it replaces would have been wrong' `
			([string]::CompareOrdinal('1.0.0.31', '1.0.0.9') -lt 0) `
			'if this fails the trap has gone away and the note can go with it'
		check 'equal versions compare equal' `
			((Compare-OS7Version -Left '1.0.0.119' -Right '1.0.0.119') -eq 0)
		check 'a minor beats a build' `
			((Compare-OS7Version -Left '1.1.0.0' -Right '1.0.9.999') -gt 0)

		$threw = $false
		try { Compare-OS7Version -Left 'banana' -Right '1.0.0.0' } catch { $threw = $true }
		check 'something that is not a version is refused, not coerced' $threw

		# -------------------------------------------------------------------
		# 2. THE KERNEL PICKED OUT OF /boot IS THE NEWEST ONE.
		#
		# An update is exactly the operation that leaves two kernels in one
		# boot environment, so this is the operation that turns a string sort
		# into a machine booting the older kernel against the newer root.
		# BUILD-NOTES #89.
		# -------------------------------------------------------------------
		$boot = [System.IO.Path]::Combine($tmp, 'boot')
		[System.IO.Directory]::CreateDirectory($boot) | Out-Null
		foreach ($k in @('7.0.0-9-generic', '7.0.0-31-generic', '7.0.0-30-generic')) {
			[System.IO.File]::WriteAllText([System.IO.Path]::Combine($boot, "vmlinuz-$k"), '')
			[System.IO.File]::WriteAllText([System.IO.Path]::Combine($boot, "initrd.img-$k"), '')
		}
		check 'the newest kernel is 7.0.0-31, not 7.0.0-9' `
			((Get-OS7NewestKernel -BootDir $boot) -eq '7.0.0-31-generic') `
			"got '$(Get-OS7NewestKernel -BootDir $boot)'"
		check 'a /boot with no kernel answers null rather than guessing' `
			($null -eq (Get-OS7NewestKernel -BootDir ([System.IO.Path]::Combine($tmp, 'nope'))))

		# -------------------------------------------------------------------
		# 3. THE PIN IS PARSED, NOT SOURCED.
		# -------------------------------------------------------------------
		$pin = [System.IO.Path]::Combine($tmp, 'release.conf')
		[System.IO.File]::WriteAllText($pin, @(
			'# a comment with OS7_SUITE="wrong" inside it'
			'OS7_SUITE="os7-1.0"'
			"OS7_REPO_URI='file:///mnt/repo'"
			'OS7_REPO_ENABLED=no'
			'   OS7_DISTRIBUTION="resolute"   '
			'NOT_A_PIN'
		) -join "`n")
		check 'a double-quoted value is unquoted' `
			((Get-OS7ReleaseConfField -Name 'OS7_SUITE' -Path $pin) -eq 'os7-1.0')
		check 'a single-quoted value is unquoted too' `
			((Get-OS7ReleaseConfField -Name 'OS7_REPO_URI' -Path $pin) -eq 'file:///mnt/repo')
		check 'an unquoted value is taken as it stands' `
			((Get-OS7ReleaseConfField -Name 'OS7_REPO_ENABLED' -Path $pin) -eq 'no')
		check 'surrounding whitespace is not part of the value' `
			((Get-OS7ReleaseConfField -Name 'OS7_DISTRIBUTION' -Path $pin) -eq 'resolute')
		check 'a comment mentioning a name does not define it' `
			((Get-OS7ReleaseConfField -Name 'OS7_SUITE' -Path $pin) -ne 'wrong')
		check 'a name that is not in the file is null, not empty' `
			($null -eq (Get-OS7ReleaseConfField -Name 'OS7_NOSUCH' -Path $pin))

		# -------------------------------------------------------------------
		# 4. MOUNT POINTS COME FROM THE KERNEL, AND THE ESCAPES ARE DECODED.
		#
		# /proc/self/mountinfo escapes space, tab and backslash in octal. A
		# reader that does not decode them reports a path that does not exist
		# and Assert-OS7UpdateRootAssembled refuses a correctly assembled tree.
		# -------------------------------------------------------------------
		$mi = [System.IO.Path]::Combine($tmp, 'mountinfo')
		[System.IO.File]::WriteAllText($mi, @(
			'25 30 0:23 / /run rw,nosuid shared:5 - tmpfs tmpfs rw'
			'26 30 0:24 / /run/os7-update rw,relatime shared:6 - zfs rpool/ROOT/os7_b rw'
			'27 26 0:25 / /run/os7-update/var/log rw shared:7 - zfs rpool/DATA/log rw'
			'28 26 0:26 / /run/os7-update/a\040b rw shared:8 - zfs rpool/DATA/x rw'
		) -join "`n")
		$mounts = Get-OS7MountedPaths -Path $mi
		check 'the kernel''s mount list is read' ($mounts.ContainsKey('/run/os7-update'))
		check 'a nested mount is read too' ($mounts.ContainsKey('/run/os7-update/var/log'))
		check 'an octal-escaped space is decoded' ($mounts.ContainsKey('/run/os7-update/a b'))
		check 'a path that is not mounted is absent' (-not $mounts.ContainsKey('/run/os7-update/var/cache'))

		# -------------------------------------------------------------------
		# 5. AN INDEX THAT HAS EXPIRED IS REFUSED.
		#
		# §6.3: authenticity and freshness are different properties, and apt's
		# Valid-Until does not cover the index. -SkipSignature is used here
		# because what is under test is the freshness decision, not gpgv.
		# -------------------------------------------------------------------
		$repo = [System.IO.Path]::Combine($tmp, 'repo')
		[System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($repo, 'index')) | Out-Null
		[System.IO.Directory]::CreateDirectory(
			[System.IO.Path]::Combine($repo, 'releases', '1.0.1.0')) | Out-Null
		$repoUri = 'file://' + $repo.Replace('\', '/')

		$descriptorPath = [System.IO.Path]::Combine($repo, 'releases', '1.0.1.0', 'release.json')
		[System.IO.File]::WriteAllText($descriptorPath,
			'{"version":"1.0.1.0","channel":"development","signing":{"development":true}}')
		$descriptorSha = Get-OS7FileSha256 -Path $descriptorPath

		$writeIndex = {
			param($validUntil, $sha)
			$doc = '{"channel":"development","valid_until":"' + $validUntil + '","releases":[' +
				'{"version":"1.0.1.0","manifest":"releases/1.0.1.0/release.json",' +
				'"manifest_sha256":"' + $sha + '"}]}'
			[System.IO.File]::WriteAllText(
				[System.IO.Path]::Combine($repo, 'index', 'development.json'), $doc)
		}

		& $writeIndex ([datetime]::UtcNow.AddDays(-1).ToString('r')) $descriptorSha
		$threw = $false
		try {
			Get-OS7ReleaseIndex -BaseUri $repoUri -Channel 'development' -WorkDir $tmp -SkipSignature | Out-Null
		}
		catch { $threw = $true }
		check 'an expired index is refused' $threw `
			'a signed index that is no longer current is how a withdrawn release stays servable'

		& $writeIndex ([datetime]::UtcNow.AddDays(30).ToString('r')) $descriptorSha
		$index = $null
		try {
			$index = Get-OS7ReleaseIndex -BaseUri $repoUri -Channel 'development' -WorkDir $tmp -SkipSignature
		}
		catch { }
		check 'a current index is accepted' ($null -ne $index)

		# The document says which channel it is, and the fetch said which
		# channel was wanted. Serving one channel's signed index under
		# another's name must be a refusal — the signature proves authorship,
		# not that this is the channel it was asked for.
		$stablePath = [System.IO.Path]::Combine($repo, 'index', 'stable.json')
		[System.IO.File]::Copy(
			[System.IO.Path]::Combine($repo, 'index', 'development.json'), $stablePath, $true)
		$threw = $false
		try {
			Get-OS7ReleaseIndex -BaseUri $repoUri -Channel 'stable' -WorkDir $tmp -SkipSignature | Out-Null
		}
		catch { $threw = $true }
		check 'an index mislabelled as another channel is refused' $threw `
			'a development listing served as stable would answer with the wrong population'
		[System.IO.File]::Delete($stablePath)

		# -------------------------------------------------------------------
		# 6. A DESCRIPTOR IS BOUND TO THE INDEX THAT NAMED IT.
		#
		# The descriptor is not signed on its own; the index is, and it records
		# the descriptor's sha256. So a descriptor whose hash does not match is
		# a descriptor nothing signed.
		# -------------------------------------------------------------------
		if ($index) {
			$entry = @(Get-OS7ManifestField $index 'releases')[0]
			$d = $null
			try { $d = Get-OS7ReleaseDescriptor -BaseUri $repoUri -IndexEntry $entry -WorkDir $tmp } catch { }
			check 'a descriptor matching the index hash is accepted' ($null -ne $d)

			& $writeIndex ([datetime]::UtcNow.AddDays(30).ToString('r')) `
				('0000000000000000000000000000000000000000000000000000000000000000')
			$bad = Get-OS7ReleaseIndex -BaseUri $repoUri -Channel 'development' -WorkDir $tmp -SkipSignature
			$badEntry = @(Get-OS7ManifestField $bad 'releases')[0]
			$threw = $false
			try { Get-OS7ReleaseDescriptor -BaseUri $repoUri -IndexEntry $badEntry -WorkDir $tmp | Out-Null }
			catch { $threw = $true }
			check 'a descriptor whose hash the index does not record is refused' $threw
		}

		# -------------------------------------------------------------------
		# 7. MIGRATIONS RUN IN NUMERIC ORDER.
		#
		# The same trap as 1 and 2, in the place C11 says the whole
		# multi-release jump depends on it: "the only sequencing is the
		# migrations, applied in order".
		# -------------------------------------------------------------------
		$mroot = [System.IO.Path]::Combine($tmp, 'root')
		$mdir = $mroot + $script:OS7MigrationDir + '/1.0.1.0/chroot'
		[System.IO.Directory]::CreateDirectory($mdir) | Out-Null
		foreach ($n in @('10-ten', '09-nine', '2-two', '31-thirtyone')) {
			[System.IO.File]::WriteAllText([System.IO.Path]::Combine($mdir, $n), '#!/bin/sh')
		}
		$order = @(Get-OS7Migration -Root $mroot -Version '1.0.1.0' |
			ForEach-Object { [System.IO.Path]::GetFileName($_) })
		check 'migrations are ordered by their numeric prefix' `
			(($order -join ',') -eq '2-two,09-nine,10-ten,31-thirtyone') `
			"got '$($order -join ',')'"
		check 'a release with no migrations yields none, not an error' `
			(@(Get-OS7Migration -Root $mroot -Version '9.9.9.9').Count -eq 0)
		check 'the firstboot context is separate from the chroot one' `
			(@(Get-OS7Migration -Root $mroot -Version '1.0.1.0' -Context 'firstboot').Count -eq 0)

		# -------------------------------------------------------------------
		# 7b. WHICH ENVIRONMENT IS RUNNING IS NOT WHICH DATASET IS MOUNTED.
		#
		# `Active` is ZFS's `mounted`, which means mounted ANYWHERE — and this
		# cmdlet mounts a boot environment at /run/os7-update for the whole of
		# an update, so during one there are two. Get-OS7RootDataset asks the
		# kernel which dataset actually serves `/`.
		# -------------------------------------------------------------------
		$mi2 = [System.IO.Path]::Combine($tmp, 'mountinfo-root')
		[System.IO.File]::WriteAllText($mi2, @(
			'22 1 0:20 / / rw,relatime shared:1 - zfs rpool/ROOT/os7_a rw,xattr,posixacl'
			'26 22 0:24 / /run/os7-update rw,relatime shared:6 - zfs rpool/ROOT/os7_b rw'
			'27 22 0:25 / /boot rw shared:7 - zfs bpool/BOOT/os7_a rw'
		) -join "`n")
		check 'the dataset serving / is the one at /, not the one mounted elsewhere' `
			((Get-OS7RootDataset -Path $mi2) -eq 'rpool/ROOT/os7_a') `
			"got '$(Get-OS7RootDataset -Path $mi2)'"

		$mi3 = [System.IO.Path]::Combine($tmp, 'mountinfo-overlay')
		[System.IO.File]::WriteAllText($mi3,
			'22 1 0:20 / / rw,relatime - overlay overlay rw,lowerdir=/x')
		check 'a machine that is not ZFS-rooted answers null rather than guessing' `
			($null -eq (Get-OS7RootDataset -Path $mi3)) `
			'a live medium is casper on overlayfs, and "which boot environment" has no answer there'

		# The fallback the two answers meet in. On a live medium `Running` is
		# $null for every environment and `Active` is the only signal there is;
		# everywhere else `Running` decides.
		check 'Running decides when the kernel could answer' `
			(Test-OS7IsRunning ([pscustomobject]@{ Running = $true; Active = $false }))
		check 'a merely-mounted environment is not the running one' `
			(-not (Test-OS7IsRunning ([pscustomobject]@{ Running = $false; Active = $true })))
		check 'and Active is the fallback when it could not' `
			(Test-OS7IsRunning ([pscustomobject]@{ Running = $null; Active = $true }))

		# -------------------------------------------------------------------
		# 8. AN INCOMPLETE ASSEMBLY IS REFUSED.
		#
		# The check this file exists for. Every dataset in a clone is
		# canmount=noauto, so a mount that did not happen leaves a directory
		# that reads exactly like an empty filesystem.
		# -------------------------------------------------------------------
		$threw = $false
		try {
			Assert-OS7UpdateRootAssembled -Root '/run/os7-update' `
				-Expected @('/run/os7-update', '/run/os7-update/var/log')
		}
		catch { $threw = $true }
		check 'a root with nothing mounted under it is refused' $threw `
			'this is what stops apt writing package state into the wrong dataset'
	}
	finally {
		try { [System.IO.Directory]::Delete($tmp, $true) } catch { }
	}

	$pass = $script:__os7UpdPass
	[Console]::Error.WriteLine("`nOS/7 Update self-test: $pass passed, $($fail.Count) failed")
	if ($fail.Count -gt 0) {
		foreach ($f in $fail) { [Console]::Error.WriteLine("  FAILED: $f") }
		[Console]::Error.WriteLine('OS/7 Update self-test: FAIL')
		return $false
	}
	[Console]::Error.WriteLine('OS/7 Update self-test: PASS')
	return $true
}
