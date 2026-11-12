# =============================================================================
# Vendor package sources — admitted, confined, kept current, and told apart
#
# docs/VENDOR-APPS-PLAN.md VA2-VA8, measured in docs/SESSION-TAILSCALE.md.
#
# A VENDOR SOURCE IS REGISTERED, NOT WRITTEN. Register-OS7PackageSource admits a
# repository in three files and a record:
#
#   /etc/os7/keyrings/<name>.gpg|.asc            the vendor key, OS/7's copy
#   /etc/apt/sources.list.d/os7-vendor-<name>.sources   Signed-By that copy
#   /etc/apt/preferences.d/os7-vendor-<name>.pref       the origin at -1,
#                                                       the named packages at 500
#   /etc/os7/package-sources/<name>.json         what was admitted, and by whom
#
# THE RECORD IS INSIDE THE BOOT ENVIRONMENT, deliberately (VA2): it describes
# which packages may come from where, and those packages, dpkg's database and
# apt's configuration all roll back together. A record outside would describe a
# package set the rolled-back environment does not have.
#
# FOUR MEASUREMENTS DECIDE THIS FILE (SESSION-TAILSCALE §1a, VENDOR-APPS O-M1):
#
#   * `Package: *` at -1 plus `Package: <name>` at 500, by `Pin: origin`, left
#     one installable package of the vendor's three, in either stanza order —
#     and kept the vendor's KEYRING PACKAGE out, which would otherwise ship the
#     key apt checks that vendor with (VA3).
#   * A keyring that does not hold the signing key is a WARNING to apt: exit 0,
#     and the old index stays on offer. So every apt run here goes through
#     Update-AptIndex, which is fail-loud and source-restricted, and its verdict
#     is written to a status file a reader can see (VA4).
#   * The documented install of a vendor package puts its state in the boot
#     environment, and a rollback then restores an identity the other side has
#     already replaced (R1). State is AU6's verb's business, before the package
#     (VA9) — the roles above this file do that, not this file.
#   * `-CheckDrift` compared nothing (M-TS13). Drift is now measured against
#     the package set OS/7 itself last made (Save-OS7PackageBaseline), and
#     classified with Get-OS7PackageOriginClass (VA8).
#
# AND ONE RULE NO MEASUREMENT IS NEEDED FOR: between releases this file
# upgrades the named packages of a source, ONLY. `install --only-upgrade
# <names>`, never `full-upgrade` — the pinned archive does not move between
# releases (VA7), and check-package-source-logic.py holds that.
#
# LAYERING: no apt, apt-cache, dpkg-query or gpg here. P2-apt.
# =============================================================================

$script:OS7PackageSourceRecordDir = '/etc/os7/package-sources'
$script:OS7PackageSourceStateDir  = '/var/lib/os7/package-sources'
$script:OS7VendorKeyringDir       = '/etc/os7/keyrings'
$script:OS7AptEtc                 = '/etc/apt'
$script:OS7VendorUpdateLog        = '/var/log/os7/vendor-update.log'
$script:OS7PackageSourceSchema    = 1

# What the release itself writes into apt's configuration: the pinned archive
# (sources.list on a fresh install, ubuntu.sources once Update-OS7 has run), the
# OS/7 repository, and the archive exception's suite (hook 0005).
$script:OS7ReleaseSourceFiles = @('sources.list', 'ubuntu.sources', 'os7.sources',
	'os7-archive-exception.list')

# The vendor sources a medium ships (VA5's `Image` class). A medium that records
# them says so in image.json (`apt_sources`); one built before it did — every
# medium up to and including 1.0.0.277 — ships exactly the four hook 0010 writes,
# named here once, with that hook as the authority.
$script:OS7ImageSourceFallback = @('microsoft-prod.sources', 'microsoft-azure-cli.sources',
	'microsoft-edge.sources', 'microsoft-vscode.sources')

function Import-OS7AptLayer {
	<#
	.SYNOPSIS
		Internal. Make the Apt module available, lazily — BUILD-NOTES #38 and
		#82, the same shape as Import-OS7DockerLayer.
	#>
	if (Get-Module -Name Apt) { return }
	$candidates = @(
		(Join-Path (Split-Path -Parent $PSScriptRoot) 'Apt/Apt.psd1'),
		'/usr/local/share/powershell/Modules/Apt/Apt.psd1'
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			Import-Module $c -Force -ErrorAction Stop
			Write-OS7Step "apt layer: $c"
			return
		}
	}
	Import-Module Apt -Force -ErrorAction Stop
	Write-OS7Step 'apt layer: Apt (by name)'
}

function Assert-OS7PackageSourceName {
	<#
	.SYNOPSIS
		Internal. A source's name becomes three file names; it is one short,
		lower-case word or it is refused.
	#>
	param([Parameter(Mandatory)][string]$Name)
	if ($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,31}$') {
		throw [System.ArgumentException]::new(
			"'$Name' is not a usable source name: lower-case letters, digits and '-', at most 32, " +
			'starting with a letter or digit. It becomes part of three file names.')
	}
}

function Get-OS7PackageSourcePath {
	<#
	.SYNOPSIS
		Internal. Where each of a source's files is, under an optional root
		(an update's assembled environment).
	#>
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][ValidateSet('Record', 'Status', 'Source', 'Preference')][string]$What,
		[string]$Root = ''
	)
	$r = $Root.TrimEnd('/')
	switch ($What) {
		'Record'     { "$r$($script:OS7PackageSourceRecordDir)/$Name.json" }
		'Status'     { "$r$($script:OS7PackageSourceStateDir)/$Name.json" }
		'Source'     { "$r$($script:OS7AptEtc)/sources.list.d/os7-vendor-$Name.sources" }
		'Preference' { "$r$($script:OS7AptEtc)/preferences.d/os7-vendor-$Name.pref" }
	}
}

function ConvertTo-OS7Fingerprint {
	<#
	.SYNOPSIS
		Internal. A fingerprint as gpg prints it: hex, upper case, no spaces.
		40 characters (v4) or 64 (v6), or it is refused.
	#>
	param([Parameter(Mandatory)][string]$Fingerprint)
	$f = ($Fingerprint -replace '\s', '').ToUpperInvariant()
	if ($f -notmatch '^([0-9A-F]{40}|[0-9A-F]{64})$') {
		throw [System.ArgumentException]::new(
			"'$Fingerprint' is not an OpenPGP fingerprint (40 or 64 hex digits). A key id is not " +
			'enough: two keys can share one, and this is the check that decides whom apt trusts.')
	}
	return $f
}

function Get-OS7PackageSourceRecord {
	<#
	.SYNOPSIS
		Internal. The registered sources' records, as objects. A record that
		does not parse is reported as such rather than skipped — a source
		nobody can read the record of is still a source apt uses.
	#>
	param([string]$Name, [string]$Root = '')
	$dir = $Root.TrimEnd('/') + $script:OS7PackageSourceRecordDir
	if (-not [System.IO.Directory]::Exists($dir)) { return @() }
	$files = @([System.IO.Directory]::GetFiles($dir, '*.json') | Sort-Object)
	if ($Name) { $files = @($files | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) -eq $Name }) }
	foreach ($f in $files) {
		$n = [System.IO.Path]::GetFileNameWithoutExtension($f)
		try {
			$doc = [System.IO.File]::ReadAllText($f) | ConvertFrom-Json -ErrorAction Stop
			[pscustomobject]@{
				Name         = $n
				Path         = $f
				Valid        = $true
				Uri          = [string]$doc.uri
				Suite        = [string]$doc.suite
				Components   = @($doc.components)
				Fingerprint  = [string]$doc.fingerprint
				Packages     = @($doc.packages)
				UpdatePolicy = [string]$doc.updatePolicy
				Keyring      = [string]$doc.keyring
				Host         = ([System.Uri]$doc.uri).Host
				Registered   = [string]$doc.registered
				RegisteredBy = [string]$doc.registeredBy
				FromRelease  = [bool]($doc.PSObject.Properties['fromRelease'] -and $doc.fromRelease)
			}
		}
		catch {
			[pscustomobject]@{
				Name = $n; Path = $f; Valid = $false; Uri = $null; Suite = $null; Components = @()
				Fingerprint = $null; Packages = @(); UpdatePolicy = $null; Keyring = $null; Host = $null
				Registered = $null; RegisteredBy = $null; FromRelease = $false
			}
		}
	}
}

function Read-OS7PackageSourceStatus {
	<#
	.SYNOPSIS
		Internal. The last verdict on a source's index, or $null.
	#>
	param([Parameter(Mandatory)][string]$Name, [string]$Root = '')
	$p = Get-OS7PackageSourcePath -Name $Name -What Status -Root $Root
	if (-not [System.IO.File]::Exists($p)) { return $null }
	try { return ([System.IO.File]::ReadAllText($p) | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Write-OS7PackageSourceStatus {
	<#
	.SYNOPSIS
		Internal. Record what the index update said. A success moves
		`verifiedAt`; a failure keeps it, so "not verified since" has a date.
	#>
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)]$Update,
		[string]$Root = ''
	)
	$p = Get-OS7PackageSourcePath -Name $Name -What Status -Root $Root
	$old = Read-OS7PackageSourceStatus -Name $Name -Root $Root
	$now = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
	$reason = @(@($Update.Failures | ForEach-Object { $_.Reason }) + @($Update.Errors)) |
		Where-Object { $_ } | Select-Object -First 1
	$doc = [ordered]@{
		schema     = $script:OS7PackageSourceSchema
		verified   = [bool]$Update.Succeeded
		checked    = $now
		verifiedAt = if ($Update.Succeeded) { $now } elseif ($old -and $old.PSObject.Properties['verifiedAt']) { $old.verifiedAt } else { $null }
		lastError  = if ($Update.Succeeded) { $null } else { [string]$reason }
		exitCode   = $Update.ExitCode
	}
	[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($p)) | Out-Null
	[System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $doc -Depth 4))
}

function Write-OS7VendorLog {
	<#
	.SYNOPSIS
		Internal. One line in /var/log/os7/vendor-update.log — outside the boot
		environment, like update.log, so a rollback does not un-say what moved.
		Never throws.
	#>
	param([Parameter(Mandatory)][string]$Message)
	try {
		[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($script:OS7VendorUpdateLog)) | Out-Null
		$stamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
		[System.IO.File]::AppendAllText($script:OS7VendorUpdateLog, "$stamp $Message`n")
	}
	catch { }
}

function Get-OS7ImageSourceFile {
	<#
	.SYNOPSIS
		Internal. The source files the medium shipped (VA5's Image class):
		image.json's `apt_sources` when the medium recorded it, else the four
		hook 0010 writes.
	#>
	param([string]$Root = '')
	$p = $Root.TrimEnd('/') + $script:OS7ImageManifest
	try {
		if ([System.IO.File]::Exists($p)) {
			$doc = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json -ErrorAction Stop
			if ($doc.PSObject.Properties['apt_sources'] -and $null -ne $doc.apt_sources) {
				return @($doc.apt_sources | ForEach-Object { [string]$_ })
			}
		}
	}
	catch { }
	return $script:OS7ImageSourceFallback
}

function Get-OS7SourceFileClass {
	<#
	.SYNOPSIS
		Internal. VA5: Release, Registered, Image or Unregistered — by file.
	#>
	param(
		[Parameter(Mandatory)][string]$File,
		[object[]]$Records = @(),
		[string[]]$ImageFiles = @()
	)
	$leaf = [System.IO.Path]::GetFileName($File)
	if ($script:OS7ReleaseSourceFiles -contains $leaf) { return 'Release' }
	if ($leaf -match '^os7-vendor-(.+)\.sources$') {
		$n = $Matches[1]
		if (@($Records | Where-Object { $_.Name -eq $n }).Count) { return 'Registered' }
	}
	if ($ImageFiles -contains $leaf) { return 'Image' }
	return 'Unregistered'
}

function Get-OS7ReleaseVendor {
	<#
	.SYNOPSIS
		Internal. A vendor source the RELEASE describes (VA1): its URI, suite,
		components, key location, fingerprint and packages from the pin —
		OS7_VENDOR_<NAME>_* in /usr/lib/os7/release.conf. $null when the pin
		names no such vendor.
	#>
	param([Parameter(Mandatory)][string]$Name)
	$k = 'OS7_VENDOR_' + ($Name.ToUpperInvariant() -replace '-', '_')
	$uri = Get-OS7ReleaseConfField -Name "${k}_URI"
	if (-not $uri) { return $null }
	$suite = Get-OS7ReleaseConfField -Name "${k}_SUITE"
	if (-not $suite) { $suite = Get-OS7ReleaseConfField -Name 'OS7_DISTRIBUTION' }
	[pscustomobject]@{
		Name        = $Name
		Uri         = $uri
		Suite       = $suite
		Components  = @(([string](Get-OS7ReleaseConfField -Name "${k}_COMPONENTS") -split '\s+') | Where-Object { $_ })
		KeyUri      = Get-OS7ReleaseConfField -Name "${k}_KEY_URI"
		Fingerprint = Get-OS7ReleaseConfField -Name "${k}_FPR"
		Packages    = @(([string](Get-OS7ReleaseConfField -Name "${k}_PACKAGES") -split '\s+') | Where-Object { $_ })
	}
}

function Test-OS7PackageSourceKeyring {
	<#
	.SYNOPSIS
		Internal. Does the keyring hold EXACTLY the key the record names?
		Returns @{ Intact; Found; Reason }.
	.DESCRIPTION
		Exactly: one primary key, that fingerprint. A keyring with a second
		primary key in it would let the second key sign this source too, which
		is the trust the fingerprint was pinned to prevent.
	#>
	param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Fingerprint)
	try {
		$keys = @(Get-AptKeyring -Path $Path)
	}
	catch {
		return [pscustomobject]@{ Intact = $false; Found = @(); Reason = $_.Exception.Message }
	}
	$found = @($keys | ForEach-Object { $_.Fingerprint })
	$intact = ($found.Count -eq 1 -and $found[0] -eq $Fingerprint)
	$reason = if ($intact) { $null }
	elseif ($found.Count -gt 1) { "$Path holds $($found.Count) primary keys ($($found -join ', ')); exactly one, $Fingerprint, is admitted." }
	else { "$Path holds $($found -join ', '); the source was admitted for $Fingerprint." }
	return [pscustomobject]@{ Intact = $intact; Found = $found; Reason = $reason }
}

function Register-OS7PackageSource {
	<#
	.SYNOPSIS
		Admits a vendor's apt repository: its key pinned by fingerprint, an apt
		preference that lets it supply ONLY the packages named, and a record.

	.DESCRIPTION
		docs/VENDOR-APPS-PLAN.md VA2-VA4. In order, and nothing is written
		before the key has been checked:

		  1  the key is fetched (https only) or read, and gpg is asked what it
		     holds: EXACTLY one primary key with the given fingerprint, or a
		     refusal that names both and writes nothing
		  2  OS/7's copy of the key under /etc/os7/keyrings — never the
		     vendor's own /usr/share/keyrings path, which the vendor's keyring
		     package owns (M-TS1)
		  3  the deb822 source, Signed-By that copy
		  4  the preference: everything from the origin at -1, the named
		     packages at 500
		  5  the record
		  6  a fail-loud index update of this source alone. A signature failure
		     here means the pinned key is not what the repository signs with:
		     everything is taken out again and the call throws. A failure for
		     any other reason (no network) leaves the source registered and
		     says it is not verified yet.

		-FromRelease takes everything but the name from the pin (VA1): the
		release says where from and signed by whom, the vendor says which
		version.

	.PARAMETER Package
		The packages this source may supply. Everything else on the same host
		gets priority -1 — including the vendor's own keyring package.

	.PARAMETER UpdatePolicy
		Follow (the timer brings them forward between releases, VA7) or Manual.

	.EXAMPLE
		Register-OS7PackageSource -Name tailscale -FromRelease

	.EXAMPLE
		Register-OS7PackageSource -Name example -Uri https://pkgs.example.com/ubuntu -Suite resolute `
		    -KeyUri https://pkgs.example.com/key.gpg -Fingerprint 0123…CDEF -Package example-agent
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Explicit')]
	[OutputType('OS7.PackageSource')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[Parameter(Mandatory, ParameterSetName = 'Explicit')][string]$Uri,
		[Parameter(ParameterSetName = 'Explicit')][string]$Suite,
		[Parameter(ParameterSetName = 'Explicit')][string[]]$Component = @('main'),
		[Parameter(Mandatory, ParameterSetName = 'Explicit')][string]$Fingerprint,
		[Parameter(ParameterSetName = 'Explicit')][string]$KeyUri,
		[Parameter(ParameterSetName = 'Explicit')][string]$KeyFile,
		[Parameter(Mandatory, ParameterSetName = 'Explicit')][string[]]$Package,
		[Parameter(Mandatory, ParameterSetName = 'Release')][switch]$FromRelease,
		[ValidateSet('Follow', 'Manual')][string]$UpdatePolicy = 'Follow',
		[switch]$Force
	)

	Assert-OS7Elevated -Cmdlet 'Register-OS7PackageSource' -Because (
		'writes a keyring under /etc/os7, an apt source and an apt preference, and refreshes that source''s index')
	Assert-OS7PackageSourceName -Name $Name
	Import-OS7AptLayer

	if ($FromRelease) {
		$v = Get-OS7ReleaseVendor -Name $Name
		if (-not $v) {
			throw [System.InvalidOperationException]::new(
				"the release describes no vendor source called '$Name' (no OS7_VENDOR_$($Name.ToUpperInvariant())_URI in " +
				"$($script:OS7ReleaseConf)). Give -Uri, -Fingerprint, -KeyUri and -Package instead.")
		}
		$Uri = $v.Uri; $Suite = $v.Suite; $KeyUri = $v.KeyUri; $Fingerprint = $v.Fingerprint
		$Package = $v.Packages
		if (@($v.Components).Count) { $Component = $v.Components }
		if (-not $Fingerprint -or -not $KeyUri -or -not @($Package).Count) {
			throw [System.InvalidOperationException]::new(
				"the release's entry for '$Name' is incomplete: it needs _URI, _KEY_URI, _FPR and _PACKAGES.")
		}
	}
	if (-not $Suite) { $Suite = Get-OS7ReleaseConfField -Name 'OS7_DISTRIBUTION' }
	if (-not $Suite) {
		throw [System.ArgumentException]::new('no -Suite given, and the release names no distribution to default to.')
	}
	$fpr = ConvertTo-OS7Fingerprint -Fingerprint $Fingerprint
	$u = $null
	if (-not [System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin @('https', 'http')) {
		throw [System.ArgumentException]::new("'$Uri' is not an http(s) URI.")
	}
	if ([bool]$KeyUri -eq [bool]$KeyFile) {
		throw [System.ArgumentException]::new('give the key as exactly one of -KeyUri or -KeyFile.')
	}
	if ($KeyUri -and -not $KeyUri.StartsWith('https://')) {
		throw [System.ArgumentException]::new(
			"the key is fetched over https only: '$KeyUri' would let anybody on the path choose the key " +
			'this machine then checks the fingerprint OF. The fingerprint check would still catch a swap; ' +
			'a refusal costs less than relying on it.')
	}

	# A SOURCE FOR THE SAME REPOSITORY WITH ANOTHER KEYRING makes apt refuse
	# EVERY source on the machine (measured: "Conflicting values set for option
	# Signed-By", exit 100). The vendor's documented install leaves exactly such
	# a file. Refused here, naming it, before anything is written — removing an
	# administrator's file is the caller's decision (a role's -Adopt makes it).
	$planned = [pscustomobject]@{ Uris = @($Uri); Suites = @($Suite); SignedBy = '(the registration)'; File = '(the registration)'; Enabled = $true }
	$clash = @(Get-OS7SourceConflict -Extra @($planned) | Where-Object {
			@($_.Files) -notcontains (Get-OS7PackageSourcePath -Name $Name -What Source) -or @($_.Files).Count -gt 2 })
	if ($clash.Count) {
		throw [System.InvalidOperationException]::new(
			"Register-OS7PackageSource refused '$Name' and wrote nothing: " +
			"$(@($clash[0].Files | Where-Object { $_ -ne '(the registration)' }) -join ', ') already names " +
			"$($clash[0].Source) with another keyring ($(@($clash[0].SignedBy | Where-Object { $_ -ne '(the registration)' }) -join ', ')). " +
			'apt refuses to read ANY source while two name one repository with different keys, so registering ' +
			'this beside it would stop every update on this machine. Remove that file, then register.')
	}

	$recordPath = Get-OS7PackageSourcePath -Name $Name -What Record
	if ([System.IO.File]::Exists($recordPath) -and -not $Force) {
		throw [System.InvalidOperationException]::new(
			"a source called '$Name' is already registered ($recordPath). -Force replaces it.")
	}

	# 1. THE KEY, CHECKED BEFORE ANYTHING IS WRITTEN.
	$scratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "os7-key-$Name-" + [guid]::NewGuid().ToString('N'))
	try {
		if ($KeyFile) {
			[System.IO.File]::Copy($KeyFile, $scratch, $true)
		}
		else {
			Invoke-WebRequest -Uri $KeyUri -OutFile $scratch -UseBasicParsing -ErrorAction Stop | Out-Null
		}
		$bytes = [System.IO.File]::ReadAllBytes($scratch)
		$armored = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(64, $bytes.Length)) -match '-----BEGIN PGP PUBLIC KEY BLOCK-----'
		$check = Test-OS7PackageSourceKeyring -Path $scratch -Fingerprint $fpr
		if (-not $check.Intact) {
			throw [System.Security.SecurityException]::new(
				"Register-OS7PackageSource refused '$Name' and wrote nothing: the key from " +
				"$(if ($KeyUri) { $KeyUri } else { $KeyFile }) is not the one admitted. $($check.Reason)")
		}

		$keyring = "$($script:OS7VendorKeyringDir)/$Name" + $(if ($armored) { '.asc' } else { '.gpg' })
		$sourcePath = Get-OS7PackageSourcePath -Name $Name -What Source
		$prefPath = Get-OS7PackageSourcePath -Name $Name -What Preference
		if (-not $PSCmdlet.ShouldProcess($Name, "admit $Uri ($Suite) for $($Package -join ', ')")) { return }

		# 2. OS/7's copy of the key.
		[System.IO.Directory]::CreateDirectory($script:OS7VendorKeyringDir) | Out-Null
		[System.IO.File]::Copy($scratch, $keyring, $true)
		try { [System.IO.File]::SetUnixFileMode($keyring, [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead') }
		catch [System.PlatformNotSupportedException] { }
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $scratch
	}

	$written = @()
	try {
		# 3. The source.
		$null = Set-AptSource -Path $sourcePath -Uri $Uri -Suite $Suite -Component $Component -SignedBy $keyring -Comment @(
			"Registered by Register-OS7PackageSource ($Name). docs/VENDOR-APPS-PLAN.md VA2.",
			"Its key is pinned to $fpr and kept at $keyring; the packages it may",
			"supply are in $prefPath. Unregister-OS7PackageSource removes all of it.") -Confirm:$false
		$written += $sourcePath

		# 4. The preference — VA3/VA4: the origin at -1, the named packages at 500.
		$null = Set-AptPreference -Path $prefPath -Comment @(
			"Registered by Register-OS7PackageSource ($Name). $($u.Host) may supply ONLY",
			"$($Package -join ', '). Everything else it publishes - its keyring package",
			'included - is at -1, so it can never be installed from here.') -Stanza @(
			@{ Package = '*'; Pin = "origin $($u.Host)"; Priority = -1 },
			@{ Package = $Package; Pin = "origin $($u.Host)"; Priority = 500 }) -Confirm:$false
		$written += $prefPath

		# 5. The record.
		[System.IO.Directory]::CreateDirectory($script:OS7PackageSourceRecordDir) | Out-Null
		$record = [ordered]@{
			schema       = $script:OS7PackageSourceSchema
			name         = $Name
			uri          = $Uri
			suite        = $Suite
			components   = @($Component)
			fingerprint  = $fpr
			packages     = @($Package)
			updatePolicy = $UpdatePolicy
			keyring      = $keyring
			source       = $sourcePath
			preference   = $prefPath
			fromRelease  = [bool]$FromRelease
			registered   = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
			registeredBy = ($env:SUDO_USER ?? $env:USER ?? 'unknown')
		}
		[System.IO.File]::WriteAllText($recordPath, (ConvertTo-Json -InputObject $record -Depth 4))
		$written += $recordPath
		Write-OS7Step "registered $Name ($($u.Host), $($Package -join ', '))"

		# 6. The index, fail-loud, this source alone.
		$idx = Update-AptIndex -SourceFile $sourcePath
		Write-OS7PackageSourceStatus -Name $Name -Update $idx
		if (-not $idx.Succeeded) {
			$why = @(@($idx.Failures | ForEach-Object { $_.Reason }) + @($idx.Errors)) | Where-Object { $_ }
			if (($why -join ' ') -match 'NO_PUBKEY|BADSIG|EXPKEYSIG|REVKEYSIG|signature') {
				throw [System.Security.SecurityException]::new(
					"$Uri does not verify against the admitted key $fpr`: $($why | Select-Object -First 1). " +
					'The repository signs with a different key than the one pinned; nothing is left registered.')
			}
			Write-Warning ("$Name is registered and its index could NOT be fetched yet: " +
				"$($why | Select-Object -First 1). Update-OS7PackageSource -Name $Name tries again.")
		}
	}
	catch {
		# Take out what this call wrote — a half-registered source is one apt
		# uses and nothing lists.
		foreach ($w in $written) { Remove-Item -Force -ErrorAction SilentlyContinue $w }
		Remove-Item -Force -ErrorAction SilentlyContinue $keyring
		Remove-Item -Force -ErrorAction SilentlyContinue (Get-OS7PackageSourcePath -Name $Name -What Status)
		throw
	}
	return (Get-OS7PackageSource -Name $Name)
}

function Get-OS7PackageSource {
	<#
	.SYNOPSIS
		The vendor sources this machine has registered — and with -All, every
		other apt source, classified.

	.DESCRIPTION
		VA2, VA4 and VA5. For a registered source: whether its keyring still
		holds exactly the admitted key, whether its index verified the last time
		it was asked and since when it has not, what it supplies that is
		installed, and what it would move. Asking it fetches nothing.

		-All adds every other source file, each with a Class:

		  Release        the pinned archive and the OS/7 repository
		  Image          vendor sources the medium shipped, unconfined —
		                 the four packages.microsoft.com files on amd64
		  Unregistered   anything else — it takes part in every Update-OS7
		                 with nothing confining it

	.EXAMPLE
		Get-OS7PackageSource -All | Format-Table Name, Class, Hosts, Verified, Attention
	#>
	[CmdletBinding()]
	[OutputType('OS7.PackageSource')]
	param(
		[Parameter(Position = 0)][string]$Name,
		[switch]$All
	)

	Import-OS7AptLayer
	$records = @(Get-OS7PackageSourceRecord)
	$sel = if ($Name) { @($records | Where-Object { $_.Name -eq $Name }) } else { $records }
	if ($Name -and -not $sel.Count) {
		throw [System.Management.Automation.ItemNotFoundException]::new("no registered source called '$Name'.")
	}

	foreach ($r in $sel) {
		$attention = [System.Collections.Generic.List[string]]::new()
		if (-not $r.Valid) {
			$attention.Add("its record $($r.Path) does not parse.")
			[pscustomobject]@{ PSTypeName = 'OS7.PackageSource'; Name = $r.Name; Class = 'Registered'; Attention = $attention.ToArray() }
			continue
		}
		$status = Read-OS7PackageSourceStatus -Name $r.Name
		$keyring = Test-OS7PackageSourceKeyring -Path $r.Keyring -Fingerprint $r.Fingerprint
		if (-not $keyring.Intact) { $attention.Add("its keyring changed: $($keyring.Reason) Nothing is installed from it until this is resolved.") }
		$files = @{ Source = (Get-OS7PackageSourcePath -Name $r.Name -What Source); Preference = (Get-OS7PackageSourcePath -Name $r.Name -What Preference) }
		foreach ($k in @($files.Keys)) {
			if (-not [System.IO.File]::Exists($files[$k])) { $attention.Add("its $($k.ToLowerInvariant()) file $($files[$k]) is missing.") }
		}
		$verified = if ($status) { [bool]$status.verified } else { $null }
		if ($status -and -not $status.verified) {
			$since = if ($status.verifiedAt) { "since $($status.verifiedAt)" } else { 'ever' }
			$attention.Add("its index has not verified $since`: $($status.lastError)")
		}

		$installed = @(); $updates = @()
		try {
			$pk = @(Get-AptPackage -Name $r.Packages | Where-Object Installed)
			$installed = @($pk | ForEach-Object { "$($_.Package) $($_.Version)" })
			if ($pk.Count) {
				$pol = @(Get-AptPolicy -Package @($pk | ForEach-Object Package))
				foreach ($p in $pol) {
					if ($p.Candidate -and $p.Installed -and $p.Candidate -ne $p.Installed -and $p.CandidateOrigin -eq $r.Host) {
						$updates += "$($p.Package) $($p.Installed) -> $($p.Candidate)"
					}
				}
			}
		}
		catch { $attention.Add("apt could not be asked: $($_.Exception.Message)") }

		[pscustomobject]@{
			PSTypeName   = 'OS7.PackageSource'
			Name         = $r.Name
			Class        = 'Registered'
			Uri          = $r.Uri
			Hosts        = @($r.Host)
			Suite        = $r.Suite
			Packages     = $r.Packages
			UpdatePolicy = $r.UpdatePolicy
			Fingerprint  = $r.Fingerprint
			KeyringIntact = $keyring.Intact
			Verified     = $verified
			VerifiedAt   = if ($status) { $status.verifiedAt } else { $null }
			LastError    = if ($status) { $status.lastError } else { $null }
			Installed    = $installed
			Updates      = $updates
			FromRelease  = $r.FromRelease
			Registered   = $r.Registered
			RegisteredBy = $r.RegisteredBy
			File         = $files.Source
			Attention    = $attention.ToArray()
		}
	}

	if (-not $All) { return }
	$conflicts = @(Get-OS7SourceConflict)
	$imageFiles = @(Get-OS7ImageSourceFile)
	$byFile = @(Get-AptSource -Directory $script:OS7AptEtc) | Group-Object File
	foreach ($g in $byFile) {
		$class = Get-OS7SourceFileClass -File $g.Name -Records $records -ImageFiles $imageFiles
		if ($class -eq 'Registered') { continue }
		$entries = @($g.Group)
		$attention = @()
		if ($class -eq 'Unregistered' -and @($entries | Where-Object Enabled).Count) {
			$attention = @("it takes part in every Update-OS7 with nothing confining it. Register-OS7PackageSource " +
				'admits a vendor source with its key pinned and the packages it may supply named.')
		}
		elseif ($class -eq 'Image') {
			$attention = @('shipped by the medium and not confined: any package it publishes can arrive in an update ' +
				'(docs/VENDOR-APPS-PLAN.md VA17).')
		}
		foreach ($c in @($conflicts | Where-Object { @($_.Files) -contains $g.Name })) {
			$attention = @("apt REFUSES EVERY SOURCE on this machine while this file and " +
				"$(@($c.Files | Where-Object { $_ -ne $g.Name }) -join ', ') name $($c.Source) with different keyrings " +
				'(Conflicting values set for option Signed-By). Remove one of them.') + $attention
		}
		[pscustomobject]@{
			PSTypeName   = 'OS7.PackageSource'
			Name         = [System.IO.Path]::GetFileName($g.Name)
			Class        = $class
			Uri          = (@($entries | ForEach-Object { $_.Uris }) | Select-Object -Unique) -join ' '
			Hosts        = @($entries | ForEach-Object { $_.Hosts } | Select-Object -Unique)
			Suite        = (@($entries | ForEach-Object { $_.Suites }) | Select-Object -Unique) -join ' '
			Packages     = @()
			UpdatePolicy = $null
			Fingerprint  = $null
			KeyringIntact = $null
			Verified     = $null
			VerifiedAt   = $null
			LastError    = $null
			Installed    = @()
			Updates      = @()
			FromRelease  = ($class -in @('Release', 'Image'))
			Registered   = $null
			RegisteredBy = $null
			File         = $g.Name
			Enabled      = [bool]@($entries | Where-Object Enabled).Count
			Attention    = $attention
		}
	}
}

function Unregister-OS7PackageSource {
	<#
	.SYNOPSIS
		Removes a registered source: its apt source, its preference, OS/7's copy
		of its key, its record and its status.

	.DESCRIPTION
		REFUSES while a package it supplies is installed, unless -Force: a
		package whose source is gone stays at its version forever and nothing
		says why. The package itself is never removed by this cmdlet — that is
		the role's uninstall, which knows what the package's state is.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[switch]$Force
	)
	Assert-OS7Elevated -Cmdlet 'Unregister-OS7PackageSource' -Because (
		'deletes an apt source, an apt preference and a keyring under /etc')
	Assert-OS7PackageSourceName -Name $Name
	Import-OS7AptLayer
	$r = @(Get-OS7PackageSourceRecord -Name $Name) | Select-Object -First 1
	if (-not $r) { throw [System.Management.Automation.ItemNotFoundException]::new("no registered source called '$Name'.") }

	$installed = @(Get-AptPackage -Name $r.Packages | Where-Object Installed)
	if ($installed.Count -and -not $Force) {
		throw [System.InvalidOperationException]::new(
			"$Name still supplies $(($installed | ForEach-Object { "$($_.Package) $($_.Version)" }) -join ', '). " +
			'Without the source that package stays at that version and nothing reports why. Remove it first, ' +
			'or -Force to leave it orphaned on purpose.')
	}
	if (-not $PSCmdlet.ShouldProcess($Name, 'remove the source, its preference, its key and its record')) { return }
	$null = Remove-AptSource -Path (Get-OS7PackageSourcePath -Name $Name -What Source) -Confirm:$false
	foreach ($p in @((Get-OS7PackageSourcePath -Name $Name -What Preference), $r.Keyring, $r.Path,
			(Get-OS7PackageSourcePath -Name $Name -What Status))) {
		if ($p -and [System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) }
	}
	Write-OS7Step "unregistered $Name"
	return (-not [System.IO.File]::Exists($r.Path))
}

function Update-OS7PackageSource {
	<#
	.SYNOPSIS
		Brings what registered sources supply up to date, IN PLACE, between
		releases — the timer's verb (VA7).

	.DESCRIPTION
		Per source: the keyring is checked against the record (a changed key
		stops that source), the index is updated for that source alone and
		fail-loud, and then the source's INSTALLED packages whose candidate
		comes from its own host are upgraded — `apt-get install --only-upgrade
		<those names>`. Never `full-upgrade`: the pinned archive moves with a
		release and not between them.

		What moved goes to /var/log/os7/vendor-update.log, and the package
		baseline is rewritten (VA8), because OS/7 just changed the package set.

		-All takes every source whose policy is Follow; a source registered
		Manual is only brought forward when named.

	.EXAMPLE
		Update-OS7PackageSource -All
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Name')]
	[OutputType('OS7.PackageSourceUpdate')]
	param(
		[Parameter(Mandatory, ParameterSetName = 'Name', Position = 0)][string[]]$Name,
		[Parameter(Mandatory, ParameterSetName = 'All')][switch]$All
	)
	Assert-OS7Elevated -Cmdlet 'Update-OS7PackageSource' -Because (
		'refreshes apt indexes and upgrades installed packages')
	Import-OS7AptLayer

	$records = @(Get-OS7PackageSourceRecord | Where-Object Valid)
	$sel = if ($All) { @($records | Where-Object { $_.UpdatePolicy -eq 'Follow' }) }
	else {
		foreach ($n in $Name) {
			if (-not @($records | Where-Object { $_.Name -eq $n }).Count) {
				throw [System.Management.Automation.ItemNotFoundException]::new("no registered source called '$n'.")
			}
		}
		@($records | Where-Object { $Name -contains $_.Name })
	}

	$movedAny = $false
	foreach ($r in $sel) {
		$res = [pscustomobject]@{
			PSTypeName = 'OS7.PackageSourceUpdate'; Name = $r.Name; Verified = $false
			Moved = @(); Error = $null
		}
		$keyring = Test-OS7PackageSourceKeyring -Path $r.Keyring -Fingerprint $r.Fingerprint
		if (-not $keyring.Intact) {
			$res.Error = "keyring changed: $($keyring.Reason)"
			Write-OS7VendorLog "$($r.Name): NOT updated, $($res.Error)"
			$res; continue
		}
		$idx = Update-AptIndex -SourceFile (Get-OS7PackageSourcePath -Name $r.Name -What Source)
		Write-OS7PackageSourceStatus -Name $r.Name -Update $idx
		if (-not $idx.Succeeded) {
			$res.Error = "index did not verify: " + (@(@($idx.Failures | ForEach-Object Reason) + @($idx.Errors)) | Where-Object { $_ } | Select-Object -First 1)
			Write-OS7VendorLog "$($r.Name): NOT updated, $($res.Error)"
			$res; continue
		}
		$res.Verified = $true
		$installed = @(Get-AptPackage -Name $r.Packages | Where-Object Installed)
		$todo = @()
		if ($installed.Count) {
			foreach ($p in @(Get-AptPolicy -Package @($installed | ForEach-Object Package))) {
				if ($p.Candidate -and $p.Installed -and $p.Candidate -ne $p.Installed -and $p.CandidateOrigin -eq $r.Host) {
					$todo += $p
				}
			}
		}
		if ($todo.Count -and $PSCmdlet.ShouldProcess($r.Name, "upgrade $(($todo | ForEach-Object Package) -join ', ')")) {
			try {
				$inst = Install-AptPackage -Name @($todo | ForEach-Object Package) -OnlyUpgrade -NoInstallRecommends -Confirm:$false
				foreach ($p in $todo) {
					$now = @($inst.Packages | Where-Object { $_.Package -eq $p.Package }) | Select-Object -First 1
					$to = if ($now) { $now.Version } else { '(gone)' }
					if ($to -ne $p.Installed) {
						$res.Moved += "$($p.Package) $($p.Installed) -> $to"
						Write-OS7VendorLog "$($r.Name): $($p.Package) $($p.Installed) -> $to"
					}
				}
			}
			catch {
				$res.Error = $_.Exception.Message
				Write-OS7VendorLog "$($r.Name): upgrade FAILED, $($res.Error)"
			}
		}
		if ($res.Moved.Count) { $movedAny = $true }
		elseif (-not $res.Error) { Write-OS7VendorLog "$($r.Name): verified, nothing to move" }
		$res
	}
	if ($movedAny) {
		try { $null = Save-OS7PackageBaseline -Reason 'Update-OS7PackageSource' -Confirm:$false }
		catch { Write-Warning "the package baseline could not be rewritten: $($_.Exception.Message)" }
	}
}

# =============================================================================
# VA8 — the baseline drift is measured against, and the classes of a change
# =============================================================================

function Save-OS7PackageBaseline {
	<#
	.SYNOPSIS
		Records the package set as it is now as the one OS/7 made — the
		reference `Get-OS7Version -CheckDrift` measures against.

	.DESCRIPTION
		docs/VENDOR-APPS-PLAN.md VA8. The image's manifest describes the MEDIUM,
		and Setup removes five packages from every install, so comparing a
		machine with it calls every fresh machine drifted (M-TS13). This file is
		written whenever OS/7 itself changes the package set — on the first
		boot, by Update-OS7 in the environment it builds, by a vendor update,
		by a role's install — so drift is "what changed since OS/7 last
		changed it".

		INSIDE THE BOOT ENVIRONMENT (/var/lib/os7), like C10's migration
		record, because it describes this environment's packages and must roll
		back with them.

		An administrator who changed packages ON PURPOSE runs it to say so.

		The format is the release manifest's — `package<TAB>version<TAB>arch`,
		sorted by byte — under a comment header.

	.PARAMETER Root
		An assembled boot environment (Update-OS7), instead of this system.

	.EXAMPLE
		Save-OS7PackageBaseline -Reason 'installed the monitoring agent on purpose'
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[string]$Reason = 'by hand',
		[string]$Root = ''
	)
	Assert-OS7Elevated -Cmdlet 'Save-OS7PackageBaseline' -Because (
		"writes $($script:OS7PackageBaseline), which is root's")
	Import-OS7AptLayer
	if ($Reason -match '[\r\n]') { throw [System.ArgumentException]::new('the reason is one line.') }
	$rows = @(Get-AptPackage -Root $Root)
	if (-not $rows.Count) {
		throw [System.InvalidOperationException]::new('dpkg listed no packages, so there is nothing to record.')
	}
	$lines = [string[]]@($rows | ForEach-Object { "$($_.BinaryPackage)`t$($_.Version)`t$($_.Architecture)" })
	[System.Array]::Sort($lines, [System.StringComparer]::Ordinal)
	$path = $Root.TrimEnd('/') + $script:OS7PackageBaseline
	$stamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
	$text = "# OS/7 package baseline - written $stamp by Save-OS7PackageBaseline: $Reason`n" +
		"# docs/VENDOR-APPS-PLAN.md VA8. Get-OS7Version -CheckDrift compares this machine with it.`n" +
		(($lines -join "`n") + "`n")
	if (-not $PSCmdlet.ShouldProcess($path, "record $($lines.Count) packages")) { return }
	[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path)) | Out-Null
	$tmp = "$path.tmp"
	[System.IO.File]::WriteAllText($tmp, $text)
	[System.IO.File]::Move($tmp, $path, $true)
	Write-OS7Step "package baseline: $($lines.Count) packages, $Reason"
	[pscustomobject]@{
		PSTypeName = 'OS7.PackageBaseline'
		Path       = $path
		Packages   = $lines.Count
		Reason     = $Reason
		Written    = $stamp
	}
}

function Get-OS7PackageOriginClass {
	<#
	.SYNOPSIS
		Internal. What drift and Update-OS7 need to tell an intended change from
		an accident: which package names registered sources supply, and which
		hosts registered and image sources are on.
	#>
	param([string]$Root = '')
	$records = @(Get-OS7PackageSourceRecord -Root $Root | Where-Object Valid)
	$pkgs = @{}
	$hosts = @{}
	foreach ($r in $records) {
		foreach ($p in $r.Packages) { $pkgs[$p] = $r.Name }
		if ($r.Host) { $hosts[$r.Host] = $r.Name }
	}
	$imageHosts = @()
	try {
		$imageFiles = @(Get-OS7ImageSourceFile -Root $Root)
		$imageHosts = @(@(Get-AptSource -Directory ($Root.TrimEnd('/') + $script:OS7AptEtc)) |
			Where-Object { (Get-OS7SourceFileClass -File $_.File -Records $records -ImageFiles $imageFiles) -eq 'Image' } |
			ForEach-Object { $_.Hosts } | Select-Object -Unique)
	}
	catch { $imageHosts = @() }
	[pscustomobject]@{
		RegisteredPackages = $pkgs
		RegisteredHosts    = $hosts
		ImageHosts         = $imageHosts
	}
}

# =============================================================================
# VA6 — what Update-OS7 does with vendor sources in the environment it builds
# =============================================================================

function Enter-OS7UpdateVendorSources {
	<#
	.SYNOPSIS
		Internal. Before the clone's apt run: every registered source's key
		checked, a source whose key changed set aside for this run, every
		unregistered source named, and the package set written down.

	.DESCRIPTION
		docs/VENDOR-APPS-PLAN.md VA5/VA6. M-TS5 measured the clone's
		full-upgrade taking tailscale 1.104.4 -> 1.104.5 from an unregistered
		source with no word anywhere but apt's history. Registered sources take
		part DELIBERATELY; an unregistered one still takes part — removing an
		administrator's source mid-update is a decision nobody has made — but it
		is named, in the update log and as a warning.

		A REGISTERED SOURCE WHOSE KEYRING NO LONGER HOLDS EXACTLY THE ADMITTED
		KEY IS SET ASIDE for this run (renamed so apt does not read it), never
		failing the update: an OS/7 update must not be hostage to a vendor's
		key (VA4). Exit-OS7UpdateVendorSources puts it back.
	#>
	param([Parameter(Mandatory)][string]$Root)

	Import-OS7AptLayer
	$records = @(Get-OS7PackageSourceRecord -Root $Root | Where-Object Valid)
	$setAside = [System.Collections.Generic.List[string]]::new()
	foreach ($r in $records) {
		$k = Test-OS7PackageSourceKeyring -Path ($Root.TrimEnd('/') + $r.Keyring) -Fingerprint $r.Fingerprint
		if ($k.Intact) { continue }
		$src = Get-OS7PackageSourcePath -Name $r.Name -What Source -Root $Root
		if ([System.IO.File]::Exists($src)) {
			[System.IO.File]::Move($src, "$src.os7-update-disabled", $true)
			$setAside.Add($src)
			Write-Warning "the vendor source $($r.Name) is left out of this update: $($k.Reason)"
			Write-OS7UpdateLog "vendor: $($r.Name) set aside for this run, $($k.Reason)"
		}
	}

	$imageFiles = @(Get-OS7ImageSourceFile -Root $Root)
	$unregistered = @(@(Get-AptSource -Directory ($Root.TrimEnd('/') + $script:OS7AptEtc)) |
		Where-Object { $_.Enabled -and (Get-OS7SourceFileClass -File $_.File -Records $records -ImageFiles $imageFiles) -eq 'Unregistered' } |
		ForEach-Object { [System.IO.Path]::GetFileName($_.File) } | Select-Object -Unique)
	foreach ($u in $unregistered) {
		Write-Warning ("$u is not a registered source and takes part in this update unconfined. " +
			'Register-OS7PackageSource admits a vendor source with its key pinned and its packages named.')
		Write-OS7UpdateLog "vendor: UNREGISTERED source $u takes part in this update"
	}

	$before = @{}
	foreach ($p in @(Get-AptPackage -Root $Root | Where-Object Installed)) { $before[$p.Package] = $p.Version }
	[pscustomobject]@{
		Conflicts    = @(Get-OS7SourceConflict -Root $Root)
		Records      = $records
		SetAside     = $setAside.ToArray()
		Unregistered = $unregistered
		Before       = $before
	}
}

function Exit-OS7UpdateVendorSources {
	<#
	.SYNOPSIS
		Internal. After the clone's apt run: what registered and image sources
		moved, attributed by the host the installed version came from; the
		sources set aside put back.
	#>
	param(
		[Parameter(Mandatory)][string]$Root,
		[Parameter(Mandatory)]$State
	)
	foreach ($src in $State.SetAside) {
		if ([System.IO.File]::Exists("$src.os7-update-disabled")) {
			[System.IO.File]::Move("$src.os7-update-disabled", $src, $true)
		}
	}

	$after = @(Get-AptPackage -Root $Root | Where-Object Installed)
	$moved = @($after | Where-Object { -not $_.Package.StartsWith('os7-') -and
			(-not $State.Before.ContainsKey($_.Package) -or $State.Before[$_.Package] -ne $_.Version) })
	if (-not $moved.Count) { return @() }

	$origin = Get-OS7PackageOriginClass -Root $Root
	$pol = @{}
	try {
		foreach ($p in @(Get-AptPolicy -Package @($moved | ForEach-Object Package) -Root $Root)) { $pol[$p.Package] = $p }
	}
	catch { }
	$out = foreach ($m in $moved) {
		$host_ = if ($pol.ContainsKey($m.Package)) { $pol[$m.Package].InstalledOrigin } else { $null }
		$class = $null; $source = $null
		if ($origin.RegisteredPackages.ContainsKey($m.Package)) {
			$class = 'Registered'; $source = $origin.RegisteredPackages[$m.Package]
		}
		elseif ($host_ -and $origin.RegisteredHosts.ContainsKey($host_)) {
			$class = 'Registered'; $source = $origin.RegisteredHosts[$host_]
		}
		elseif ($host_ -and @($origin.ImageHosts) -contains $host_) {
			$class = 'Image'; $source = $host_
		}
		if (-not $class) { continue }
		$from = if ($State.Before.ContainsKey($m.Package)) { $State.Before[$m.Package] } else { '(new)' }
		Write-OS7UpdateLog "vendor: $($m.Package) $from -> $($m.Version) ($class, $source)"
		[pscustomobject]@{
			PSTypeName = 'OS7.UpdateVendorPackage'
			Package    = $m.Package
			From       = $from
			To         = $m.Version
			Class      = $class
			Source     = $source
			Host       = $host_
		}
	}
	return @($out)
}

function Get-OS7SourceConflict {
	<#
	.SYNOPSIS
		Internal. Sources apt will refuse to read TOGETHER: the same URI and
		suite with two different Signed-By keyrings.

	.DESCRIPTION
		MEASURED 2026-11-09 on 1.0.0.279: Tailscale's documented
		`tailscale.list` (Signed-By /usr/share/keyrings/…) beside the registered
		source (Signed-By /etc/os7/keyrings/…) made apt print

		    E: Conflicting values set for option Signed-By regarding source
		       https://pkgs.tailscale.com/stable/ubuntu/ resolute: …
		    E: The list of sources could not be read.

		and exit 100 — for EVERY source on the machine, so no update of any
		kind could run. One conflict object per URI+suite, naming every file.

	.PARAMETER Extra
		A source about to be written (Register), checked against what is there.
	#>
	param([string]$Root = '', [object[]]$Extra = @())
	$all = @(@(Get-AptSource -Directory ($Root.TrimEnd('/') + $script:OS7AptEtc)) | Where-Object Enabled) + @($Extra)
	$groups = @{}
	foreach ($s in $all) {
		foreach ($u in @($s.Uris)) {
			foreach ($su in @($s.Suites)) {
				$k = ($u.TrimEnd('/') + ' ' + $su)
				if (-not $groups.ContainsKey($k)) { $groups[$k] = [System.Collections.Generic.List[object]]::new() }
				$groups[$k].Add($s)
			}
		}
	}
	foreach ($k in $groups.Keys) {
		$keys = @($groups[$k] | ForEach-Object { [string]$_.SignedBy } | Select-Object -Unique)
		if ($keys.Count -gt 1) {
			[pscustomobject]@{
				Source   = $k
				Files    = @($groups[$k] | ForEach-Object { [string]$_.File } | Select-Object -Unique)
				SignedBy = $keys
			}
		}
	}
}
