# =============================================================================
# Apt — package sources, keyrings, preferences and packages, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like Zfs, Hardware and
# Docker. It knows apt, apt-cache, dpkg-query and gpg and nothing about OS/7:
# which source a machine admits, which package may come from it, and whether a
# change is drift are decided one layer up, in OS7.PackageSource.ps1
# (docs/VENDOR-APPS-PLAN.md VA2-VA8). P2-apt in installer/testing/
# check-layering.py keeps powershell/OS7 from calling these programs itself.
#
# FOUR THINGS MEASURED 2026-11-09 on an installed 1.0.0.277 and in ubuntu:26.04
# (docs/SESSION-TAILSCALE.md §1a, VENDOR-APPS-PLAN O-M1), each of which decides
# a piece of this file:
#
#   1. `apt-get update` EXITS 0 WHEN A SIGNATURE DOES NOT VERIFY. With a
#      keyring that does not hold the signing key it printed NO_PUBKEY as a
#      warning, said "the previous index files will be used", exited 0 — and
#      apt-cache went on offering the package from the index it had trusted
#      before. A vendor that rotates its key stops delivering updates and
#      nothing says so. `--error-on=any` makes the same run exit 100. AND THE
#      ERROR LINES ARE THERE EITHER WAY: the recording without the switch
#      carries the identical `E: Failed to fetch …` lines at exit 0. So
#      Update-AptIndex judges by the exit code AND by the lines, and a fixture
#      holds each half.
#
#   2. A RESTRICTED UPDATE IS THREE OPTIONS. `-o Dir::Etc::SourceList=/dev/null
#      -o Dir::Etc::SourceParts=<a directory holding one file>` updates exactly
#      that source; `-o APT::List-Cleanup=0` keeps apt from treating every
#      other source's lists as stale. The archive's lists were still there
#      afterwards (17 files before and after).
#
#   3. A PIN BY ORIGIN CONFINES A REPOSITORY TO THE PACKAGES NAMED. `Package: *`
#      at -1 and `Package: <name>` at 500, both `Pin: origin <host>`, left one
#      installable package of the vendor's three, IN EITHER STANZA ORDER. Under
#      the pin, apt-cache's version table shows the version at 500 and the
#      source line under it at -1 — both numbers are real and they answer
#      different questions, so Get-AptPolicy keeps both.
#
#   4. THE LOCALE. A machine installed in German answers "Holen:" and
#      "Installiert:" (BUILD-NOTES #176), so every program here runs under
#      LC_ALL=C.UTF-8 — the parsers below match English, and only English.
#
# ONE FUNCTION RUNS A PROGRAM: Invoke-AptCommand, not exported. It is the seam
# Test-AptModule replays recorded output through, and the reason the layering
# rule can be a grep: a product cmdlet that wanted apt-get would have to name it.
# =============================================================================

Set-StrictMode -Version 3.0

# The self-test's seam: a scriptblock taking (command, arguments, root) and
# returning what Invoke-AptCommand returns. $null in production, not exported.
$script:AptCommandOverride = $null

# The file names apt itself reads from sources.list.d and preferences.d. Anything
# else in those directories — `os7.sources.dpkg-dist`, an editor's backup — is
# NOT a source, and reporting it as one would be inventing configuration.
$script:AptSourceFileName = '^[A-Za-z0-9_.\-]+\.(list|sources)$'
$script:AptPreferenceFileName = '^[A-Za-z0-9_.\-]+$'

function Write-AptStep {
	<#
	.SYNOPSIS
		Internal. One line of progress, on stderr, in the shape every layer here
		uses (ZFS-STEP, OS7-STEP), so a caller can read progress apart from data.
	#>
	param([Parameter(Mandatory)][string]$Message)
	[Console]::Error.WriteLine("APT-STEP $Message")
}

function Invoke-AptCommand {
	<#
	.SYNOPSIS
		Internal. Run apt, apt-cache, dpkg-query or gpg and return stdout,
		stderr and the exit code, without judging the exit code.

	.DESCRIPTION
		IN THE C LOCALE, ALWAYS, and non-interactively: LC_ALL=C.UTF-8 and
		DEBIAN_FRONTEND=noninteractive through `env`, so the parsers read the
		words they were written against (#176) and no maintainer script waits
		for a person.

		-Root runs the command inside a chroot — how an update asks the
		environment it has assembled rather than the one it is running on.
		Same shape as Invoke-HardwareCommand, for the same reason.
	#>
	param(
		[Parameter(Mandatory)][string]$Command,
		[string[]]$Arguments = @(),
		[string]$Root = ''
	)

	if ($script:AptCommandOverride) {
		return & $script:AptCommandOverride $Command $Arguments $Root
	}

	$exe = 'env'
	$argv = @('LC_ALL=C.UTF-8', 'DEBIAN_FRONTEND=noninteractive', $Command) + $Arguments
	if ($Root -and $Root -ne '/') {
		# chroot <root> env LC_ALL=… <command> … — the environment is set INSIDE
		# the chroot, by the chroot's own env.
		$exe = 'chroot'
		$argv = @($Root, 'env') + $argv
	}

	$errFile = [System.IO.Path]::GetTempFileName()
	try {
		# RESET, THEN GUARDED READ — BUILD-NOTES #121. A command that is found
		# and cannot be started neither throws nor sets $LASTEXITCODE.
		$global:LASTEXITCODE = $null
		$out = & $exe @argv 2> $errFile
		$code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
		return [pscustomobject]@{
			StdOut   = (@($out) -join "`n")
			ExitCode = $code
			StdErr   = ((Get-Content -Raw -ErrorAction SilentlyContinue $errFile) ?? '')
		}
	}
	catch {
		# The program is not on this machine. Reported as exit 127, the shell's
		# own word for it, so a caller can tell "not installed" from "failed".
		return [pscustomobject]@{ StdOut = ''; ExitCode = 127; StdErr = [string]$_ }
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $errFile
	}
}

function Assert-AptElevated {
	<#
	.SYNOPSIS
		Internal. This layer's own root guard, in the words the product's uses.

	.DESCRIPTION
		BUILD-NOTES #149: a generic layer cannot call Assert-OS7Elevated without
		inverting P2, so the verbs below that write apt's configuration, its
		lists or dpkg's database carry their own — Assert-DockerElevated's shape.
		The kernel is asked (/proc/self/status, the effective uid), not a
		command, and a host with no /proc (the self-test on Windows) is not a
		refusal.
	#>
	param(
		[Parameter(Mandatory)][string]$Cmdlet,
		[Parameter(Mandatory)][string]$Because
	)
	$status = '/proc/self/status'
	if (-not [System.IO.File]::Exists($status)) { return }
	$uid = $null
	foreach ($line in [System.IO.File]::ReadAllLines($status)) {
		if (-not $line.StartsWith('Uid:')) { continue }
		$f = $line.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)
		if ($f.Count -ge 3) { $uid = $f[2] }
		break
	}
	if ($null -eq $uid -or $uid -eq '0') { return }
	throw [System.InvalidOperationException]::new(
		"$Cmdlet must run as root: it $Because. This process is uid $uid. Elevate the shell: " +
		"sudo pwsh -NoProfile -c '$Cmdlet <parameters>'")
}

# =============================================================================
# Files: deb822 stanzas, sources and preferences
# =============================================================================

function ConvertFrom-AptStanza {
	<#
	.SYNOPSIS
		Internal. RFC 822-style stanzas (deb822 sources, apt preferences) as a
		list of case-insensitive ordered dictionaries.

	.DESCRIPTION
		Field names are case-insensitive, as apt reads them. A field that
		appears TWICE in one stanza is joined, not overwritten: Edge's own
		postinst writes `Architectures: amd64` twice into its source file
		(measured on 1.0.0.277), apt accepts it, and a parser that kept only one
		line would agree with apt here by luck and disagree the first time the
		two lines differ. A continuation line (leading whitespace) belongs to
		the field above it — a deb822 `Signed-By:` may carry a whole key.
	#>
	param([AllowEmptyString()][string]$Text)

	$stanzas = [System.Collections.Generic.List[object]]::new()
	$cur = $null
	$last = $null
	foreach ($raw in ($Text -split "`n")) {
		$line = $raw.TrimEnd("`r")
		if ($line -match '^\s*#') { continue }
		if ($line.Trim() -eq '') {
			if ($null -ne $cur) { $stanzas.Add($cur) }
			$cur = $null
			$last = $null
			continue
		}
		if ($line -match '^[ \t]' -and $null -ne $cur -and $last) {
			$cur[$last] = ([string]$cur[$last] + "`n" + $line.Trim()).Trim()
			continue
		}
		if ($line -match '^([A-Za-z0-9][A-Za-z0-9-]*)\s*:\s?(.*)$') {
			if ($null -eq $cur) {
				$cur = [System.Collections.Specialized.OrderedDictionary]::new(
					[System.StringComparer]::OrdinalIgnoreCase)
			}
			$k = $Matches[1]
			$v = $Matches[2].Trim()
			if ($cur.Contains($k)) { $cur[$k] = ([string]$cur[$k] + ' ' + $v).Trim() }
			else { $cur[$k] = $v }
			$last = $k
		}
	}
	if ($null -ne $cur) { $stanzas.Add($cur) }
	return , $stanzas
}

function Split-AptValue {
	<#
	.SYNOPSIS
		Internal. A whitespace-separated field as distinct words, in order.
	#>
	param([AllowNull()][AllowEmptyString()][string]$Value)
	if ([string]::IsNullOrWhiteSpace($Value)) { return , @() }
	$seen = [System.Collections.Generic.List[string]]::new()
	foreach ($w in ($Value -split '\s+')) {
		if ($w -and -not $seen.Contains($w)) { $seen.Add($w) }
	}
	return , $seen.ToArray()
}

function Get-AptUriHost {
	<#
	.SYNOPSIS
		Internal. The host apt derives from a source URI — what `Pin: origin`
		matches. Empty for file:, cdrom: and anything that is not a URI.
	#>
	param([string]$Uri)
	$u = $null
	if ([System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$u) -and
		$u.Scheme -in @('http', 'https')) {
		return $u.Host
	}
	return ''
}

function New-AptSourceObject {
	param($File, $Format, $Index, $Types, $Uris, $Suites, $Components, $Architectures,
		$SignedBy, $Enabled)
	[pscustomobject]@{
		PSTypeName    = 'Apt.Source'
		File          = $File
		Format        = $Format
		Index         = $Index
		Types         = @($Types)
		Uris          = @($Uris)
		Hosts         = @(@($Uris) | ForEach-Object { Get-AptUriHost -Uri $_ } | Where-Object { $_ } | Select-Object -Unique)
		Suites        = @($Suites)
		Components    = @($Components)
		Architectures = @($Architectures)
		SignedBy      = $SignedBy
		Enabled       = [bool]$Enabled
	}
}

function ConvertFrom-AptOneLineSource {
	<#
	.SYNOPSIS
		Internal. The one-line format: `deb [opt=val …] uri suite component…`.
		Commented-out lines are not sources and are not returned.
	#>
	param([string]$Text, [string]$File)
	$n = 0
	foreach ($raw in ($Text -split "`n")) {
		$line = ($raw -replace '#.*$', '').Trim()
		if (-not $line) { continue }
		$n++
		$opts = @{}
		if ($line -match '^(\S+)\s+\[([^\]]*)\]\s+(.*)$') {
			# The groups are copied out FIRST: the option loop below runs -match
			# again, and $Matches is one automatic variable, not one per match.
			$type = $Matches[1]
			$optText = $Matches[2]
			$rest = $Matches[3] -split '\s+'
			foreach ($o in ($optText.Trim() -split '\s+')) {
				if ($o -match '^([^=]+)=(.*)$') { $opts[$Matches[1]] = $Matches[2] }
			}
		}
		else {
			$parts = $line -split '\s+'
			$type = $parts[0]
			$rest = @($parts | Select-Object -Skip 1)
		}
		if (@($rest).Count -lt 2) { continue }
		New-AptSourceObject -File $File -Format 'list' -Index $n -Types @($type) `
			-Uris @($rest[0]) -Suites @($rest[1]) -Components @($rest | Select-Object -Skip 2) `
			-Architectures (Split-AptValue (([string]$opts['arch']) -replace ',', ' ')) `
			-SignedBy ([string]$opts['signed-by']) -Enabled $true
	}
}

function Get-AptSource {
	<#
	.SYNOPSIS
		Every source apt reads on this machine — sources.list and every
		.list and .sources file in sources.list.d — one object per entry.

	.DESCRIPTION
		Files whose names apt would not read are not reported: `os7.sources.dpkg-dist`
		is not a source because apt does not treat it as one. A deb822 stanza
		with `Enabled: no` IS reported, with Enabled $false — it is configuration
		somebody wrote, and hiding it would make a disabled source and an absent
		one the same answer.

	.PARAMETER Directory
		The apt configuration directory. /etc/apt, or a chroot's.

	.PARAMETER Path
		One file instead of the whole directory.

	.EXAMPLE
		Get-AptSource | Format-Table File, Types, Uris, Suites, Enabled
	#>
	[CmdletBinding()]
	[OutputType('Apt.Source')]
	param(
		[string]$Directory = '/etc/apt',
		[string]$Path
	)

	$files = [System.Collections.Generic.List[string]]::new()
	if ($Path) {
		if (-not [System.IO.File]::Exists($Path)) {
			throw [System.IO.FileNotFoundException]::new("no source file at $Path.")
		}
		$files.Add($Path)
	}
	else {
		$main = [System.IO.Path]::Combine($Directory, 'sources.list')
		if ([System.IO.File]::Exists($main)) { $files.Add($main) }
		$d = [System.IO.Path]::Combine($Directory, 'sources.list.d')
		if ([System.IO.Directory]::Exists($d)) {
			foreach ($f in @([System.IO.Directory]::GetFiles($d) | Sort-Object)) {
				if ([System.IO.Path]::GetFileName($f) -match $script:AptSourceFileName) { $files.Add($f) }
			}
		}
	}

	foreach ($f in $files) {
		$text = [System.IO.File]::ReadAllText($f)
		if ($f.EndsWith('.sources')) {
			$i = 0
			foreach ($s in (ConvertFrom-AptStanza -Text $text)) {
				$i++
				$enabled = -not ([string]$s['Enabled'] -match '^(no|false|0)$')
				New-AptSourceObject -File $f -Format 'deb822' -Index $i `
					-Types (Split-AptValue $s['Types']) -Uris (Split-AptValue $s['URIs']) `
					-Suites (Split-AptValue $s['Suites']) -Components (Split-AptValue $s['Components']) `
					-Architectures (Split-AptValue $s['Architectures']) `
					-SignedBy ([string]$s['Signed-By']) -Enabled $enabled
			}
		}
		else {
			ConvertFrom-AptOneLineSource -Text $text -File $f
		}
	}
}

function Assert-AptWord {
	<#
	.SYNOPSIS
		Internal. Refuse a value that would change the file's MEANING rather
		than its content: whitespace inside one word, a newline, a `#`.
	#>
	param([string]$What, [string[]]$Value)
	foreach ($v in $Value) {
		if ([string]::IsNullOrWhiteSpace($v) -or $v -match '[\s#]') {
			throw [System.ArgumentException]::new(
				"$What '$v' is not one word. A space, a newline or a '#' would be read by apt as " +
				'something else, so it is refused rather than written.')
		}
	}
}

function Write-AptFileAtomically {
	<#
	.SYNOPSIS
		Internal. Write a file beside its target and move it into place, so apt
		never reads half of one. 0644 on Linux.
	#>
	param([string]$Path, [string]$Text)
	$dir = [System.IO.Path]::GetDirectoryName($Path)
	[System.IO.Directory]::CreateDirectory($dir) | Out-Null
	$tmp = [System.IO.Path]::Combine($dir, '.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N'))
	[System.IO.File]::WriteAllText($tmp, $Text)
	try {
		[System.IO.File]::SetUnixFileMode($tmp, [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead')
	}
	catch [System.PlatformNotSupportedException] { }
	[System.IO.File]::Move($tmp, $Path, $true)
}

function Set-AptSource {
	<#
	.SYNOPSIS
		Writes ONE deb822 source file and reads it back.

	.DESCRIPTION
		deb822 and never the one-line format: it is the form apt documents as
		current, it carries Signed-By as a field rather than an option in
		brackets, and it has `Enabled:`. Every value is one word (Assert-AptWord)
		and the file is read back through Get-AptSource before anything is
		returned — what apt will read is what is reported.

	.EXAMPLE
		Set-AptSource -Path /etc/apt/sources.list.d/x.sources -Uri https://example/ubuntu -Suite resolute -SignedBy /etc/os7/keyrings/x.gpg
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('Apt.Source')]
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][string[]]$Uri,
		[Parameter(Mandatory)][string[]]$Suite,
		[string[]]$Component = @('main'),
		[string]$SignedBy,
		[string[]]$Architecture = @(),
		[string[]]$Type = @('deb'),
		[switch]$Disabled,
		[string[]]$Comment = @()
	)

	Assert-AptElevated -Cmdlet 'Set-AptSource' -Because 'writes apt''s configuration'
	if (-not $Path.EndsWith('.sources')) {
		throw [System.ArgumentException]::new("'$Path' does not end in .sources, so apt would not read it as deb822.")
	}
	Assert-AptWord -What 'URI' -Value $Uri
	Assert-AptWord -What 'suite' -Value $Suite
	Assert-AptWord -What 'component' -Value $Component
	Assert-AptWord -What 'type' -Value $Type
	if (@($Architecture).Count) { Assert-AptWord -What 'architecture' -Value $Architecture }
	if ($SignedBy) {
		Assert-AptWord -What 'Signed-By' -Value @($SignedBy)
		if (-not $SignedBy.StartsWith('/')) {
			throw [System.ArgumentException]::new("Signed-By '$SignedBy' is not an absolute path.")
		}
	}

	$lines = [System.Collections.Generic.List[string]]::new()
	foreach ($c in $Comment) { foreach ($cl in ($c -split "`n")) { $lines.Add('# ' + $cl.TrimEnd()) } }
	$lines.Add('Types: ' + ($Type -join ' '))
	$lines.Add('URIs: ' + ($Uri -join ' '))
	$lines.Add('Suites: ' + ($Suite -join ' '))
	$lines.Add('Components: ' + ($Component -join ' '))
	if (@($Architecture).Count) { $lines.Add('Architectures: ' + ($Architecture -join ' ')) }
	if ($SignedBy) { $lines.Add('Signed-By: ' + $SignedBy) }
	if ($Disabled) { $lines.Add('Enabled: no') }
	$text = ($lines -join "`n") + "`n"

	if (-not $PSCmdlet.ShouldProcess($Path, 'write an apt source')) { return }
	Write-AptFileAtomically -Path $Path -Text $text
	Write-AptStep "wrote $Path"

	# READ IT BACK. The file is the claim; what apt's own grammar makes of it is
	# the answer.
	$back = @(Get-AptSource -Path $Path)
	$ok = $back.Count -eq 1 -and
		(@($back[0].Uris) -join ' ') -eq ($Uri -join ' ') -and
		(@($back[0].Suites) -join ' ') -eq ($Suite -join ' ') -and
		(@($back[0].Components) -join ' ') -eq ($Component -join ' ') -and
		[string]$back[0].SignedBy -eq [string]$SignedBy -and
		$back[0].Enabled -eq (-not $Disabled)
	if (-not $ok) {
		throw [System.InvalidOperationException]::new(
			"$Path was written and does not read back as written.")
	}
	return $back[0]
}

function Remove-AptSource {
	<#
	.SYNOPSIS
		Deletes one source file. Returns $true when it was there and is gone.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory)][string]$Path)
	Assert-AptElevated -Cmdlet 'Remove-AptSource' -Because 'deletes a file from apt''s configuration'
	if (-not [System.IO.File]::Exists($Path)) { return $false }
	if (-not $PSCmdlet.ShouldProcess($Path, 'delete an apt source')) { return $false }
	[System.IO.File]::Delete($Path)
	Write-AptStep "removed $Path"
	return (-not [System.IO.File]::Exists($Path))
}

function Get-AptPreference {
	<#
	.SYNOPSIS
		The apt preferences (pins) on this machine, one object per stanza.

	.DESCRIPTION
		/etc/apt/preferences and every file in preferences.d whose name apt
		reads (no extension, or `.pref`). PinPriority is an integer; a stanza
		whose priority is not one is reported with $null, because apt ignores
		it too.
	#>
	[CmdletBinding()]
	[OutputType('Apt.Preference')]
	param(
		[string]$Directory = '/etc/apt',
		[string]$Path
	)

	$files = [System.Collections.Generic.List[string]]::new()
	if ($Path) {
		if (-not [System.IO.File]::Exists($Path)) {
			throw [System.IO.FileNotFoundException]::new("no preferences file at $Path.")
		}
		$files.Add($Path)
	}
	else {
		$main = [System.IO.Path]::Combine($Directory, 'preferences')
		if ([System.IO.File]::Exists($main)) { $files.Add($main) }
		$d = [System.IO.Path]::Combine($Directory, 'preferences.d')
		if ([System.IO.Directory]::Exists($d)) {
			foreach ($f in @([System.IO.Directory]::GetFiles($d) | Sort-Object)) {
				$leaf = [System.IO.Path]::GetFileName($f)
				if ($leaf -match $script:AptPreferenceFileName -and
					($leaf -notmatch '\.' -or $leaf.EndsWith('.pref'))) { $files.Add($f) }
			}
		}
	}

	foreach ($f in $files) {
		foreach ($s in (ConvertFrom-AptStanza -Text ([System.IO.File]::ReadAllText($f)))) {
			$prio = $null
			$p = 0
			if ([int]::TryParse([string]$s['Pin-Priority'], [ref]$p)) { $prio = $p }
			[pscustomobject]@{
				PSTypeName  = 'Apt.Preference'
				File        = $f
				Package     = Split-AptValue $s['Package']
				Pin         = [string]$s['Pin']
				PinPriority = $prio
				Explanation = [string]$s['Explanation']
			}
		}
	}
}

function Set-AptPreference {
	<#
	.SYNOPSIS
		Writes ONE preferences file from a list of stanzas and reads it back.

	.PARAMETER Stanza
		Hashtables with Package (one name, several, or *), Pin and Priority.

	.EXAMPLE
		Set-AptPreference -Path /etc/apt/preferences.d/x.pref -Stanza @(
		    @{ Package = '*';  Pin = 'origin example.com'; Priority = -1 },
		    @{ Package = 'x';  Pin = 'origin example.com'; Priority = 500 })
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('Apt.Preference')]
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][hashtable[]]$Stanza,
		[string[]]$Comment = @()
	)

	Assert-AptElevated -Cmdlet 'Set-AptPreference' -Because 'writes apt''s configuration'
	$leaf = [System.IO.Path]::GetFileName($Path)
	if ($leaf -notmatch $script:AptPreferenceFileName -or ($leaf -match '\.' -and -not $leaf.EndsWith('.pref'))) {
		throw [System.ArgumentException]::new(
			"apt reads a preferences file only with no extension or '.pref'; '$leaf' would be ignored.")
	}
	$lines = [System.Collections.Generic.List[string]]::new()
	foreach ($c in $Comment) { foreach ($cl in ($c -split "`n")) { $lines.Add('# ' + $cl.TrimEnd()) } }
	$first = $true
	foreach ($s in $Stanza) {
		$pkgs = @($s['Package'])
		Assert-AptWord -What 'package' -Value $pkgs
		$pin = [string]$s['Pin']
		if (-not $pin -or $pin -match '[\r\n#]') {
			throw [System.ArgumentException]::new("pin '$pin' is empty or not one line.")
		}
		if (-not $first) { $lines.Add('') }
		$first = $false
		$lines.Add('Package: ' + ($pkgs -join ' '))
		$lines.Add('Pin: ' + $pin)
		$lines.Add('Pin-Priority: ' + [int]$s['Priority'])
	}
	$text = ($lines -join "`n") + "`n"

	if (-not $PSCmdlet.ShouldProcess($Path, 'write apt preferences')) { return }
	Write-AptFileAtomically -Path $Path -Text $text
	Write-AptStep "wrote $Path"

	$back = @(Get-AptPreference -Path $Path)
	if ($back.Count -ne @($Stanza).Count) {
		throw [System.InvalidOperationException]::new(
			"$Path was written with $(@($Stanza).Count) stanza(s) and reads back with $($back.Count).")
	}
	for ($i = 0; $i -lt $back.Count; $i++) {
		if ((@($back[$i].Package) -join ' ') -ne (@($Stanza[$i]['Package']) -join ' ') -or
			$back[$i].PinPriority -ne [int]$Stanza[$i]['Priority']) {
			throw [System.InvalidOperationException]::new(
				"$Path stanza $($i + 1) does not read back as written.")
		}
	}
	return $back
}

# =============================================================================
# Keyrings
# =============================================================================

function ConvertFrom-AptGpgColon {
	<#
	.SYNOPSIS
		Internal. `gpg --with-colons` as one object per PRIMARY key.

	.DESCRIPTION
		pub opens a key, the `fpr` after it is the key's fingerprint, `uid`
		lines are its user ids, and each `sub` opens a subkey whose `fpr`
		follows. The record type is field 1 and the fingerprint field 10, per
		GnuPG's doc/DETAILS.
	#>
	param([string]$Text)
	$keys = [System.Collections.Generic.List[object]]::new()
	$key = $null
	$expect = $null
	foreach ($line in ($Text -split "`n")) {
		$f = $line.TrimEnd("`r").Split(':')
		if ($f.Count -lt 2) { continue }
		switch ($f[0]) {
			'pub' {
				$created = $null
				$epoch = 0L
				if ($f.Count -gt 5 -and [long]::TryParse($f[5], [ref]$epoch)) {
					$created = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime
				}
				$key = [pscustomobject]@{
					PSTypeName  = 'Apt.Key'
					Fingerprint = $null
					KeyId       = if ($f.Count -gt 4) { $f[4] } else { $null }
					Algorithm   = if ($f.Count -gt 3) { $f[3] } else { $null }
					Length      = if ($f.Count -gt 2) { $f[2] } else { $null }
					Created     = $created
					UserIds     = [System.Collections.Generic.List[string]]::new()
					Subkeys     = [System.Collections.Generic.List[string]]::new()
				}
				$keys.Add($key)
				$expect = 'primary'
			}
			'sub' { $expect = 'sub' }
			'fpr' {
				if ($null -ne $key -and $f.Count -gt 9) {
					if ($expect -eq 'primary') { $key.Fingerprint = $f[9] }
					elseif ($expect -eq 'sub') { $key.Subkeys.Add($f[9]) }
				}
				$expect = $null
			}
			'uid' { if ($null -ne $key -and $f.Count -gt 9) { $key.UserIds.Add($f[9]) } }
		}
	}
	return , $keys
}

function Get-AptKeyring {
	<#
	.SYNOPSIS
		The OpenPGP keys in a keyring file — binary or armored — with their
		fingerprints.

	.DESCRIPTION
		gpg reads the file in a THROWAWAY home directory (--homedir, removed
		afterwards). The question "which key is in this file" must not depend
		on whatever root's own ~/.gnupg holds, and must not leave a keybox
		behind as a side effect of asking it (measured: the first gpg call on a
		fresh machine creates ~/.gnupg/pubring.kbx).

		Throws when the file holds no key, with gpg's own sentence.

	.EXAMPLE
		(Get-AptKeyring /usr/share/keyrings/ubuntu-archive-keyring.gpg).Fingerprint
	#>
	[CmdletBinding()]
	[OutputType('Apt.Key')]
	param([Parameter(Mandatory, Position = 0)][string]$Path)

	if (-not $script:AptCommandOverride -and -not [System.IO.File]::Exists($Path)) {
		throw [System.IO.FileNotFoundException]::new("no keyring at $Path.")
	}
	# $gpgHome AND NOT $home: $HOME is an automatic variable, and PowerShell's
	# variable names are case-insensitive (BUILD-NOTES #65's family).
	$gpgHome = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'os7-apt-gpg-' + [guid]::NewGuid().ToString('N'))
	[System.IO.Directory]::CreateDirectory($gpgHome) | Out-Null
	try {
		try { [System.IO.File]::SetUnixFileMode($gpgHome, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
		catch [System.PlatformNotSupportedException] { }
		$r = Invoke-AptCommand -Command 'gpg' -Arguments @('--batch', '--no-default-keyring',
			'--homedir', $gpgHome, '--show-keys', '--with-colons', '--with-fingerprint', $Path)
	}
	finally {
		Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $gpgHome
	}
	$keys = ConvertFrom-AptGpgColon -Text $r.StdOut
	if ($r.ExitCode -ne 0 -or $keys.Count -eq 0) {
		$said = (($r.StdErr, $r.StdOut) -join "`n").Trim()
		throw [System.IO.InvalidDataException]::new(
			"$Path holds no OpenPGP key gpg can read (exit $($r.ExitCode)): $said")
	}
	return $keys.ToArray()
}

# =============================================================================
# apt-cache policy
# =============================================================================

function ConvertFrom-AptPolicy {
	<#
	.SYNOPSIS
		Internal. `apt-cache policy <package…>` as one object per package.

	.DESCRIPTION
		The shape, read off apt 3.2.1:

		  tailscale:
		    Installed: 1.104.4
		    Candidate: 1.104.5
		    Version table:
		       1.104.5 500
		           -1 https://pkgs.tailscale.com/stable/ubuntu resolute/main amd64 Packages
		   *** 1.104.4 500
		           -1 https://pkgs.tailscale.com/stable/ubuntu resolute/main amd64 Packages
		          100 /var/lib/dpkg/status

		A version line is ONE plus THREE (`***` or spaces) plus ONE characters
		before the version; a source line is indented further and starts with
		its priority. TWO PRIORITIES, AND BOTH ARE KEPT: the version's (500,
		from the package-specific pin) and its source's (-1, from the
		origin-wide one). Which one apt uses is apt's business; what an operator
		needs is to see that the pin is doing what it says.

		A package apt does not know prints nothing at all, so it is simply not
		in the result. Callers ask by name and treat absence as the answer.
	#>
	param([string]$Text)

	$out = [System.Collections.Generic.List[object]]::new()
	$pkg = $null
	$ver = $null
	foreach ($raw in ($Text -split "`n")) {
		$line = $raw.TrimEnd("`r")
		if ($line -match '^(\S+):$') {
			$pkg = [pscustomobject]@{
				PSTypeName        = 'Apt.Policy'
				Package           = $Matches[1]
				Installed         = $null
				Candidate         = $null
				Versions          = [System.Collections.Generic.List[object]]::new()
				CandidatePriority = $null
				CandidateOrigin   = $null
				InstalledOrigin   = $null
			}
			$out.Add($pkg)
			$ver = $null
			continue
		}
		if ($null -eq $pkg) { continue }
		if ($line -match '^\s+Installed:\s*(.+)$') {
			$v = $Matches[1].Trim(); $pkg.Installed = if ($v -eq '(none)') { $null } else { $v }; continue
		}
		if ($line -match '^\s+Candidate:\s*(.+)$') {
			$v = $Matches[1].Trim(); $pkg.Candidate = if ($v -eq '(none)') { $null } else { $v }; continue
		}
		if ($line -match '^ (\*\*\*|   ) (\S+) (-?\d+)$') {
			$ver = [pscustomobject]@{
				Version   = $Matches[2]
				Priority  = [int]$Matches[3]
				Installed = ($Matches[1] -eq '***')
				Sources   = [System.Collections.Generic.List[object]]::new()
			}
			$pkg.Versions.Add($ver)
			continue
		}
		if ($line -match '^ {6,}(-?\d+) (\S+)(.*)$' -and $null -ne $ver) {
			$uri = $Matches[2]
			$tail = $Matches[3].Trim() -split '\s+'
			$ver.Sources.Add([pscustomobject]@{
					Priority = [int]$Matches[1]
					Uri      = $uri
					Host     = Get-AptUriHost -Uri $uri
					Dist     = if ($tail.Count -ge 1 -and $tail[0]) { $tail[0] } else { $null }
					Status   = ($uri -eq '/var/lib/dpkg/status')
				})
		}
	}

	foreach ($p in $out) {
		$cand = @($p.Versions | Where-Object { $_.Version -eq $p.Candidate }) | Select-Object -First 1
		if ($cand) {
			$p.CandidatePriority = $cand.Priority
			$p.CandidateOrigin = @(@($cand.Sources) | Where-Object { $_.Host }) | ForEach-Object Host | Select-Object -First 1
		}
		$inst = @($p.Versions | Where-Object { $_.Installed }) | Select-Object -First 1
		if ($inst) {
			$p.InstalledOrigin = @(@($inst.Sources) | Where-Object { $_.Host }) | ForEach-Object Host | Select-Object -First 1
		}
	}
	return , $out
}

function Get-AptPolicy {
	<#
	.SYNOPSIS
		What apt would install for each named package, from where, at which
		priority — `apt-cache policy`, as objects.

	.DESCRIPTION
		CandidateOrigin and InstalledOrigin are the HOST of the first source
		that offers that version — what `Pin: origin` matches. InstalledOrigin
		is $null for a version only dpkg's status knows (installed from a file,
		or from a source that has since gone).

	.EXAMPLE
		Get-AptPolicy tailscale | Format-List Installed, Candidate, CandidateOrigin, CandidatePriority
	#>
	[CmdletBinding()]
	[OutputType('Apt.Policy')]
	param(
		[Parameter(Mandatory, Position = 0)][string[]]$Package,
		[string]$Root = ''
	)
	$r = Invoke-AptCommand -Command 'apt-cache' -Arguments (@('policy') + $Package) -Root $Root
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"apt-cache policy exited $($r.ExitCode): $(($r.StdErr).Trim())")
	}
	return (ConvertFrom-AptPolicy -Text $r.StdOut).ToArray()
}

# =============================================================================
# The index
# =============================================================================

function ConvertFrom-AptUpdate {
	<#
	.SYNOPSIS
		Internal. What `apt-get update` said: its E: and W: lines and every
		`Err:` with the reason on the line below it.
	#>
	param([string]$Text, $ExitCode)

	$lines = @($Text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
	$errors = [System.Collections.Generic.List[string]]::new()
	$warnings = [System.Collections.Generic.List[string]]::new()
	$failures = [System.Collections.Generic.List[object]]::new()
	for ($i = 0; $i -lt $lines.Count; $i++) {
		$l = $lines[$i]
		if ($l.StartsWith('E: ')) { $errors.Add($l.Substring(3)) }
		elseif ($l.StartsWith('W: ')) { $warnings.Add($l.Substring(3)) }
		elseif ($l -match '^Err:\d+\s+(\S+)\s*(.*)$') {
			$reason = if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s+(.+)$') { $Matches[1].Trim() } else { '' }
			$failures.Add([pscustomobject]@{ Uri = $Matches[1]; What = $Matches[2]; Reason = $reason })
		}
	}
	# BY THE EXIT CODE AND BY THE LINES. Without --error-on=any apt exits 0
	# with these exact E: lines (the noerroron fixture); with it, 100. Either
	# alone has been wrong on this machine.
	[pscustomobject]@{
		PSTypeName = 'Apt.IndexUpdate'
		Succeeded  = ($ExitCode -eq 0 -and $errors.Count -eq 0 -and $failures.Count -eq 0)
		ExitCode   = $ExitCode
		Errors     = $errors.ToArray()
		Warnings   = $warnings.ToArray()
		Failures   = $failures.ToArray()
	}
}

function Update-AptIndex {
	<#
	.SYNOPSIS
		`apt-get update`, made to FAIL when a signature does not verify — for
		the whole machine, or for the named source files only.

	.DESCRIPTION
		--error-on=any always: without it apt exits 0 on a key that does not
		match and keeps the index it trusted last (§1 of the header). Succeeded
		is $true only when the exit code is 0 AND apt printed no E: line and no
		Err: line.

		-SourceFile restricts the run to those files: they are copied into a
		directory of their own under /run, apt is pointed at it with
		Dir::Etc::SourceList=/dev/null and Dir::Etc::SourceParts, and
		APT::List-Cleanup=0 keeps every other source's lists. The machine's
		sources.list.d is not touched.

	.EXAMPLE
		Update-AptIndex -SourceFile /etc/apt/sources.list.d/os7-vendor-tailscale.sources
	#>
	[CmdletBinding()]
	[OutputType('Apt.IndexUpdate')]
	param(
		[string[]]$SourceFile = @(),
		[string]$Root = ''
	)

	Assert-AptElevated -Cmdlet 'Update-AptIndex' -Because 'rewrites apt''s package lists under /var/lib/apt'
	$argv = @('update', '--error-on=any')
	$work = $null
	try {
		if (@($SourceFile).Count) {
			$prefix = if ($Root -and $Root -ne '/') { $Root.TrimEnd('/') } else { '' }
			$base = if ([System.IO.Directory]::Exists($prefix + '/run')) { '/run' } else { [System.IO.Path]::GetTempPath().TrimEnd('/', '\') }
			$inner = "$base/os7-apt-" + [guid]::NewGuid().ToString('N')
			$work = $prefix + $inner
			[System.IO.Directory]::CreateDirectory($work) | Out-Null
			foreach ($f in $SourceFile) {
				$from = $prefix + $f
				if (-not [System.IO.File]::Exists($from)) {
					throw [System.IO.FileNotFoundException]::new("no source file at $f.")
				}
				[System.IO.File]::Copy($from, [System.IO.Path]::Combine($work, [System.IO.Path]::GetFileName($f)), $true)
			}
			$argv += @('-o', 'Dir::Etc::SourceList=/dev/null', '-o', "Dir::Etc::SourceParts=$inner",
				'-o', 'APT::List-Cleanup=0')
		}
		$r = Invoke-AptCommand -Command 'apt-get' -Arguments $argv -Root $Root
	}
	finally {
		if ($work) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }
	}
	$res = ConvertFrom-AptUpdate -Text (($r.StdOut, $r.StdErr) -join "`n") -ExitCode $r.ExitCode
	$res | Add-Member -NotePropertyName Sources -NotePropertyValue @($SourceFile) -Force
	return $res
}

# =============================================================================
# Packages
# =============================================================================

function Get-AptPackage {
	<#
	.SYNOPSIS
		Packages dpkg knows, with version, architecture and state — all of
		them, or the named ones.

	.DESCRIPTION
		Installed is $true for dpkg's `ii` and `hi` (installed, held or not).
		`rc` — removed, configuration left — is reported with Installed $false.
		A named package dpkg has never heard of is simply absent; dpkg-query
		says so on stderr and exits 1, which is an answer and not a failure.

	.EXAMPLE
		Get-AptPackage tailscale
	#>
	[CmdletBinding()]
	[OutputType('Apt.Package')]
	param(
		[Parameter(Position = 0)][string[]]$Name = @(),
		[string]$Root = ''
	)
	$fmt = '-f=${binary:Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n'
	$r = Invoke-AptCommand -Command 'dpkg-query' -Arguments (@('-W', $fmt) + $Name) -Root $Root
	if ($r.ExitCode -notin @(0, 1)) {
		throw [System.InvalidOperationException]::new(
			"dpkg-query exited $($r.ExitCode): $(($r.StdErr).Trim())")
	}
	foreach ($line in ($r.StdOut -split "`n")) {
		$f = $line.TrimEnd("`r").Split("`t")
		if ($f.Count -lt 4 -or -not $f[0]) { continue }
		$status = $f[3].Trim()
		[pscustomobject]@{
			PSTypeName   = 'Apt.Package'
			Package      = ($f[0] -split ':')[0]
			# dpkg's own ${binary:Package}, `name:arch` for a Multi-Arch: same
			# package. Kept verbatim: a caller hashing the package list (the
			# release manifest's format) must hash what dpkg printed.
			BinaryPackage = $f[0]
			Version      = $f[1]
			Architecture = $f[2]
			Status       = $status
			Installed    = ($status -match '^[hi]i')
		}
	}
}

function Install-AptPackage {
	<#
	.SYNOPSIS
		apt-get install, then asks dpkg whether it happened.

	.DESCRIPTION
		Each -Name may carry a version (`name=1.2.3`). Afterwards dpkg is asked
		for every named package and the call THROWS if one is not installed —
		apt exits 0 in cases where the package asked for was not the package
		installed, and the exit code is a diagnostic of apt, not of the machine.

		--force-confold always: a configuration file an administrator changed
		is kept, and the question dpkg would otherwise ask has nobody to answer
		it.

	.EXAMPLE
		Install-AptPackage tailscale -NoInstallRecommends
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType('Apt.Install')]
	param(
		[Parameter(Mandatory, Position = 0)][string[]]$Name,
		[switch]$OnlyUpgrade,
		[switch]$NoInstallRecommends,
		[switch]$AllowDowngrades,
		[string]$Root = ''
	)
	Assert-AptElevated -Cmdlet 'Install-AptPackage' -Because 'installs packages'
	Assert-AptWord -What 'package' -Value $Name
	$argv = @('install', '-y', '-o', 'Dpkg::Options::=--force-confold')
	if ($NoInstallRecommends) { $argv += '--no-install-recommends' }
	if ($OnlyUpgrade) { $argv += '--only-upgrade' }
	if ($AllowDowngrades) { $argv += '--allow-downgrades' }
	$argv += $Name

	if (-not $PSCmdlet.ShouldProcess(($Name -join ', '), 'apt-get install')) { return }
	$r = Invoke-AptCommand -Command 'apt-get' -Arguments $argv -Root $Root
	$names = @($Name | ForEach-Object { ($_ -split '=')[0] })
	$after = @(Get-AptPackage -Name $names -Root $Root)
	$said = @((($r.StdOut, $r.StdErr) -join "`n") -split "`n" | Where-Object { $_ -match '^E: ' })
	if ($r.ExitCode -ne 0) {
		throw [System.InvalidOperationException]::new(
			"apt-get install $($Name -join ' ') exited $($r.ExitCode): $($said -join ' | ')")
	}
	$missing = @($names | Where-Object { $n = $_; -not @($after | Where-Object { $_.Package -eq $n -and $_.Installed }) })
	if ($missing.Count -and -not $OnlyUpgrade) {
		throw [System.InvalidOperationException]::new(
			"apt-get install exited 0 and dpkg reports $($missing -join ', ') not installed.")
	}
	Write-AptStep "installed: $(($after | ForEach-Object { "$($_.Package) $($_.Version)" }) -join ', ')"
	[pscustomobject]@{
		PSTypeName = 'Apt.Install'
		Requested  = @($Name)
		ExitCode   = $r.ExitCode
		Packages   = $after
	}
}

function Remove-AptPackage {
	<#
	.SYNOPSIS
		apt-get remove (or purge), then asks dpkg whether it happened.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	[OutputType('Apt.Package')]
	param(
		[Parameter(Mandatory, Position = 0)][string[]]$Name,
		[switch]$Purge,
		[string]$Root = ''
	)
	Assert-AptElevated -Cmdlet 'Remove-AptPackage' -Because 'removes packages'
	Assert-AptWord -What 'package' -Value $Name
	$verb = if ($Purge) { 'purge' } else { 'remove' }
	if (-not $PSCmdlet.ShouldProcess(($Name -join ', '), "apt-get $verb")) { return }
	$r = Invoke-AptCommand -Command 'apt-get' -Arguments (@($verb, '-y') + $Name) -Root $Root
	$after = @(Get-AptPackage -Name $Name -Root $Root)
	$still = @($after | Where-Object { $_.Installed })
	if ($r.ExitCode -ne 0 -or $still.Count) {
		$said = @((($r.StdOut, $r.StdErr) -join "`n") -split "`n" | Where-Object { $_ -match '^(E: |dpkg: |rm: )' })
		throw [System.InvalidOperationException]::new(
			"apt-get $verb $($Name -join ' ') exited $($r.ExitCode); dpkg reports " +
			"$(if ($still.Count) { ($still | ForEach-Object { "$($_.Package) $($_.Status)" }) -join ', ' } else { 'nothing installed' }). " +
			($said -join ' | '))
	}
	Write-AptStep "$verb`: $($Name -join ', ')"
	return $after
}

# =============================================================================
# The self-test
# =============================================================================

function Test-AptModule {
	<#
	.SYNOPSIS
		Checks this module against RECORDED real apt, apt-cache, dpkg-query and
		gpg output from an OS/7 machine. No apt, no root, any host.

	.NOTES
		Reports through [Console]::Error and THROWS on failure, for the reason
		every self-test here does: a function that returns $false leaves pwsh
		exiting 0, so a self-test that failed would be an image that passed.
	#>
	[CmdletBinding()]
	param([string]$FixturePath)

	if (-not $FixturePath) { $FixturePath = Join-Path $PSScriptRoot 'tests/fixtures' }
	if (-not (Test-Path -LiteralPath $FixturePath)) {
		throw [System.IO.FileNotFoundException]::new(
			"the recorded fixtures are not beside the module: $FixturePath")
	}
	$script:__aptPass = 0
	$script:__aptFail = @()
	function Check([bool]$ok, [string]$what, [string]$detail = '') {
		$line = "      {0}  {1}" -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $what
		if ($detail) { $line += "   [$detail]" }
		[Console]::Error.WriteLine($line)
		if ($ok) { $script:__aptPass++ } else { $script:__aptFail += $what }
	}
	function Fixture([string]$name) {
		$o = [System.IO.File]::ReadAllText((Join-Path $FixturePath "$name.out"))
		$rc = [int]([System.IO.File]::ReadAllText((Join-Path $FixturePath "$name.rc")).Trim())
		[pscustomobject]@{ StdOut = $o; StdErr = ''; ExitCode = $rc }
	}
	# The recording shell captured stdout and stderr as one stream; dpkg-query
	# put its complaint FIRST. Replayed as stdout, which is the harder case for
	# the parser, not the easier one.
	$seen = [System.Collections.Generic.List[string]]::new()
	function Replay([string]$name) {
		# The fixture is read HERE and the closure captures the object: the
		# override runs from Invoke-AptCommand's scope, where a function defined
		# inside this test is not visible.
		$fx = Fixture $name
		$log = $seen
		$script:AptCommandOverride = {
			param($c, $a, $r)
			$log.Add(($c + ' ' + ($a -join ' ')).Trim())
			$fx
		}.GetNewClosure()
	}

	[Console]::Error.WriteLine("`nApt self-test — no apt, no root")
	[Console]::Error.WriteLine("  against recorded output in $FixturePath")
	$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('os7-apt-test-' + [guid]::NewGuid().ToString('N'))
	try {
		# -- sources -------------------------------------------------------------
		[Console]::Error.WriteLine("`n  sources, as an OS/7 1.0.0.277 machine has them")
		$etc = Join-Path $FixturePath 'etc-apt'
		$src = @(Get-AptSource -Directory $etc)
		$byFile = { param($leaf) @($src | Where-Object { [System.IO.Path]::GetFileName($_.File) -eq $leaf }) }
		$one = & $byFile 'sources.list'
		Check ($one.Count -eq 6) 'sources.list: six one-line entries (three deb, three deb-src)' "$($one.Count)"
		Check ((@($one | Where-Object { @($_.Types) -contains 'deb' })).Count -eq 3) 'and three of them are deb'
		Check (((@($one | ForEach-Object { $_.Hosts } | Select-Object -Unique)) -join ',') -eq 'snapshot.ubuntu.com') 'all on snapshot.ubuntu.com'
		$os7 = & $byFile 'os7.sources'
		Check ($os7.Count -eq 1 -and -not $os7[0].Enabled) 'os7.sources is reported, and as DISABLED (Enabled: no)'
		$edge = & $byFile 'microsoft-edge.sources'
		Check ($edge.Count -eq 1 -and (@($edge[0].Architectures) -join ' ') -eq 'amd64') `
			"Edge's file says Architectures twice; read as one value" "$(@($edge[0].Architectures) -join '|')"
		Check ($edge[0].Hosts -contains 'packages.microsoft.com') 'its host is packages.microsoft.com'
		$ts = & $byFile 'os7-vendor-tailscale.sources'
		Check ($ts.Count -eq 1 -and $ts[0].SignedBy -eq '/etc/os7/keyrings/tailscale.gpg' -and $ts[0].Format -eq 'deb822') `
			'the vendor source: deb822, Signed-By the OS/7 keyring'
		Check ((@($ts[0].Suites) -join ' ') -eq 'resolute' -and (@($ts[0].Components) -join ' ') -eq 'main') 'suite resolute, component main'

		New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'sources.list.d') | Out-Null
		[System.IO.File]::WriteAllText((Join-Path $tmp 'sources.list.d/os7.sources.dpkg-dist'), "Types: deb`nURIs: http://x/`nSuites: y`nComponents: z`n")
		[System.IO.File]::WriteAllText((Join-Path $tmp 'sources.list.d/kept.list'), "# deb http://commented/ out main`ndeb [arch=amd64,arm64 signed-by=/k.gpg] http://h.example/ubuntu s main contrib`n")
		$t = @(Get-AptSource -Directory $tmp)
		Check ($t.Count -eq 1) 'a .dpkg-dist file and a commented line are not sources' "$($t.Count)"
		Check ($t.Count -eq 1 -and $t[0].SignedBy -eq '/k.gpg' -and (@($t[0].Architectures) -join ' ') -eq 'amd64 arm64') `
			'one-line options in brackets: signed-by, arch=a,b'

		$w = Join-Path $tmp 'sources.list.d/written.sources'
		$back = Set-AptSource -Path $w -Uri 'https://pkgs.example/ubuntu' -Suite resolute -SignedBy '/etc/os7/keyrings/x.gpg' -Comment 'line one' -Confirm:$false 2>$null
		Check ($null -ne $back -and $back.Hosts -contains 'pkgs.example') 'Set-AptSource writes deb822 and reads it back'
		$refused = $false
		try { Set-AptSource -Path $w -Uri 'https://a b' -Suite s -Confirm:$false 2>$null | Out-Null } catch { $refused = $true }
		Check $refused 'a URI with a space in it is refused, not written'
		$refused = $false
		try { Set-AptSource -Path (Join-Path $tmp 'x.list') -Uri 'https://a' -Suite s -Confirm:$false 2>$null | Out-Null } catch { $refused = $true }
		Check $refused 'a file apt would not read as deb822 is refused'

		# -- preferences ---------------------------------------------------------
		[Console]::Error.WriteLine("`n  preferences")
		$prefs = @(Get-AptPreference -Directory $etc)
		$vp = @($prefs | Where-Object { [System.IO.Path]::GetFileName($_.File) -eq 'os7-vendor-tailscale.pref' })
		Check ($vp.Count -eq 2) 'the vendor preference has two stanzas' "$($vp.Count)"
		Check ($vp.Count -eq 2 -and (@($vp[0].Package) -join ' ') -eq '*' -and $vp[0].PinPriority -eq -1 -and $vp[0].Pin -eq 'origin pkgs.tailscale.com') `
			'the first: everything from the origin at -1'
		Check ($vp.Count -eq 2 -and (@($vp[1].Package) -join ' ') -eq 'tailscale' -and $vp[1].PinPriority -eq 500) `
			'the second: the one package at 500'
		$ex = @($prefs | Where-Object { [System.IO.Path]::GetFileName($_.File) -eq 'os7-desktop-exclusions.pref' })
		Check ($ex.Count -ge 5 -and -not @($ex | Where-Object { $null -eq $_.PinPriority })) 'the desktop exclusions read as stanzas with priorities' "$($ex.Count)"
		$pw = Join-Path $tmp 'p.pref'
		$pb = @(Set-AptPreference -Path $pw -Stanza @(@{ Package = '*'; Pin = 'origin h.example'; Priority = -1 }, @{ Package = @('a', 'b'); Pin = 'origin h.example'; Priority = 500 }) -Confirm:$false 2>$null)
		Check ($pb.Count -eq 2 -and (@($pb[1].Package) -join ' ') -eq 'a b') 'Set-AptPreference writes two stanzas and reads them back'
		$refused = $false
		try { Set-AptPreference -Path (Join-Path $tmp 'p.conf') -Stanza @(@{ Package = 'a'; Pin = 'origin x'; Priority = 1 }) -Confirm:$false 2>$null | Out-Null } catch { $refused = $true }
		Check $refused 'a preferences file apt would ignore (.conf) is refused'

		# -- keyrings ------------------------------------------------------------
		[Console]::Error.WriteLine("`n  keyrings (gpg --show-keys --with-colons)")
		Replay 'gpg-show-binary'
		$k = @(Get-AptKeyring -Path '/etc/os7/keyrings/tailscale.gpg')
		Check ($k.Count -eq 1 -and $k[0].Fingerprint -eq '2596A99EAAB33821893C0A79458CA832957F5868') "Tailscale's primary fingerprint"
		Check ($k.Count -eq 1 -and @($k[0].Subkeys) -contains '2F625B3A774B946822EDDBEEB1547A3DDAAF03C6') 'its encryption subkey is a SUBKEY, not a second primary'
		Check ($k.Count -eq 1 -and ($k[0].UserIds -join '') -match 'Tailscale Inc') 'and its user id'
		Check (($seen | Select-Object -Last 1) -match '--homedir \S+ --show-keys') 'gpg is asked in a throwaway home directory'
		Replay 'gpg-show-two'
		$k = @(Get-AptKeyring -Path '/usr/share/keyrings/microsoft-legacy.gpg')
		Check ($k.Count -eq 1 -and $k[0].Fingerprint -eq 'BC528686B50D79E339D3721CEB3E94ADBE1229CF') "Microsoft's legacy key (no subkey)"
		Replay 'gpg-show-garbage'
		$threw = $false
		try { Get-AptKeyring -Path '/etc/hostname' | Out-Null } catch { $threw = $_.Exception.Message -match 'no OpenPGP key' }
		Check $threw 'a file that is not a key THROWS, naming gpg''s answer'

		# -- policy --------------------------------------------------------------
		[Console]::Error.WriteLine("`n  apt-cache policy under the vendor pin")
		Replay 'policy-pinned'
		$p = @(Get-AptPolicy -Package tailscale, tailscale-archive-keyring, tailscale-nginx-auth, bash, no-such-package-os7)
		# $policyOf AND NOT $P: $P and $p are the same variable (#65).
		$policyOf = { param($n) @($p | Where-Object Package -eq $n) | Select-Object -First 1 }
		$t1 = & $policyOf 'tailscale'
		Check ($null -ne $t1 -and $t1.Candidate -eq '1.104.5' -and $null -eq $t1.Installed) 'tailscale: candidate 1.104.5, not installed'
		Check ($null -ne $t1 -and $t1.CandidatePriority -eq 500 -and $t1.CandidateOrigin -eq 'pkgs.tailscale.com') `
			'at 500 (the package pin), from pkgs.tailscale.com'
		Check ($null -ne $t1 -and @($t1.Versions[0].Sources)[0].Priority -eq -1) 'the source line under it says -1 (the origin pin) — both kept'
		$t2 = & $policyOf 'tailscale-archive-keyring'
		Check ($null -ne $t2 -and $null -eq $t2.Candidate) 'tailscale-archive-keyring: NO candidate'
		$t3 = & $policyOf 'tailscale-nginx-auth'
		Check ($null -ne $t3 -and $null -eq $t3.Candidate -and @($t3.Versions | Where-Object Priority -eq -1).Count -eq 3) `
			'tailscale-nginx-auth: no candidate, three versions at -1'
		$t4 = & $policyOf 'bash'
		Check ($null -ne $t4 -and $t4.Installed -eq '5.3-2ubuntu1' -and $t4.InstalledOrigin -eq 'snapshot.ubuntu.com') 'bash: installed, from the snapshot'
		Check ($null -eq (& $policyOf 'no-such-package-os7')) 'a package apt does not know is absent, not invented'
		Replay 'policy-installed-older'
		$o = @(Get-AptPolicy -Package tailscale)[0]
		Check ($o.Installed -eq '1.104.4' -and $o.Candidate -eq '1.104.5' -and $o.InstalledOrigin -eq 'pkgs.tailscale.com') `
			'installed 1.104.4 from the vendor, candidate 1.104.5'
		Replay 'policy-installed-newest'
		$o = @(Get-AptPolicy -Package tailscale)[0]
		Check ($o.Installed -eq '1.104.5' -and $o.Candidate -eq '1.104.5') 'after the upgrade: installed is the candidate'

		# -- the index -----------------------------------------------------------
		[Console]::Error.WriteLine("`n  apt-get update, restricted to one source")
		$sf = Join-Path $tmp 'sources.list.d/written.sources'
		Replay 'update-restricted-ok'
		$u = Update-AptIndex -SourceFile $sf
		Check ($u.Succeeded -and $u.ExitCode -eq 0) 'a good key: Succeeded'
		$cmd = $seen | Select-Object -Last 1
		Check ($cmd -match '--error-on=any' -and $cmd -match 'Dir::Etc::SourceList=/dev/null' -and $cmd -match 'Dir::Etc::SourceParts=\S+' -and $cmd -match 'APT::List-Cleanup=0') `
			'asked with --error-on=any, SourceList=/dev/null, SourceParts and List-Cleanup=0'
		Replay 'update-restricted-badkey'
		$u = Update-AptIndex -SourceFile $sf
		Check (-not $u.Succeeded -and $u.ExitCode -eq 100) 'a key that does not hold the signer: NOT Succeeded, exit 100'
		Check (@($u.Failures | Where-Object Reason -match 'NO_PUBKEY 458CA832957F5868').Count -eq 1) 'and the failure carries apt''s reason (NO_PUBKEY)'
		Replay 'update-restricted-badkey-noerroron'
		$u = Update-AptIndex -SourceFile $sf
		Check (-not $u.Succeeded -and $u.ExitCode -eq 0) 'the same at exit 0 (apt without --error-on) is STILL not Succeeded — the lines decide too'

		# -- packages ------------------------------------------------------------
		[Console]::Error.WriteLine("`n  dpkg-query")
		Replay 'dpkg-query'
		$d = @(Get-AptPackage -Name tailscale, bash, no-such-package-os7)
		Check ($d.Count -eq 2) 'two packages; the unknown one is absent, and dpkg-query''s complaint is not a package' "$($d.Count)"
		Check (@($d | Where-Object { $_.Package -eq 'tailscale' -and $_.Version -eq '1.104.4' -and $_.Installed }).Count -eq 1) 'tailscale 1.104.4, installed (ii)'

		# -- the environment every program runs in ------------------------------
		$script:AptCommandOverride = $null
		Check ((Get-Command Invoke-AptCommand).ScriptBlock.ToString() -match "'LC_ALL=C\.UTF-8'") `
			'every program is asked in the C locale (#176)'
	}
	catch {
		# A STATEMENT-TERMINATING ERROR INSIDE try/finally ABANDONS THE REST OF
		# THE CHECKS AND EXECUTION CONTINUES AFTER THE try — so without this
		# catch the verdict below counts only the checks that ran and says PASS,
		# and pwsh exits 0 (measured 2026-11-10: Test-TailscaleModule's first run
		# printed a PropertyNotFoundException after three checks and then PASS).
		Check $false "the self-test stopped before its end: $($_.Exception.Message)"
	}
	finally {
		$script:AptCommandOverride = $null
		Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
	}

	$pass = $script:__aptPass
	$fail = $script:__aptFail
	# THE VERDICT LINE IS THE ONE THE IMAGE CHECK GREPS FOR, worded exactly like
	# every other module's (check-image.py reads them all the same way).
	[Console]::Error.WriteLine("`nApt self-test: $pass passed, $($fail.Count) failed")
	if ($fail.Count -gt 0) {
		foreach ($f in $fail) { [Console]::Error.WriteLine("    FAILED: $f") }
		[Console]::Error.WriteLine('Apt self-test: FAIL')
		throw [System.InvalidOperationException]::new(
			"Test-AptModule: $($fail.Count) of $($pass + $fail.Count) checks failed.")
	}
	[Console]::Error.WriteLine('Apt self-test: PASS')
}

Export-ModuleMember -Function Get-AptSource, Set-AptSource, Remove-AptSource,
	Get-AptPreference, Set-AptPreference, Get-AptKeyring, Get-AptPolicy,
	Update-AptIndex, Get-AptPackage, Install-AptPackage, Remove-AptPackage,
	Test-AptModule
