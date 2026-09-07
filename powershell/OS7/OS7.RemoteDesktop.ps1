# =============================================================================
# OS/7 — Remote Desktop (RDP), as an operator asks about it
#
# Layer 3 of docs/POWERSHELL-SURFACE-PLAN.md P2, and docs/REMOTE-DESKTOP-PLAN.md
# is the design. R14 decided there is NO generic module: gnome-remote-desktop is
# one daemon, one six-key config and one tool, and nearly everything OS/7 does
# with it IS policy — the credential, the certificate placement, the firewall
# stance. A `powershell/Grd/` would be P2 applied by reflex, which P2 forbids in
# the same paragraph. That is the OS7.Remoting.ps1 precedent, for the same
# reason. `grdctl` is on no check-layering.py token list.
#
# THE UNIT IS REACHED THROUGH THE Systemd MODULE, never `systemctl` — P2-systemd.
# `grdctl` does its own enable/start (measured, M-R1), which is the vendor tool
# doing vendor work; what OS/7 adds is the RESTART grdctl has no verb for.
#
# WHAT IS OS/7's KNOWLEDGE HERE, and why this is not a pass-through:
#
#   * THAT THERE ARE TWO LOGINS, and only the second one is the person's.
#     A client is authenticated at the door by NLA/CredSSP against a
#     MACHINE-WIDE credential (username `os7-rdp`) checked before any screen
#     exists — the daemon REQUIRES NLA and refuses every other security
#     protocol (M-R14) — and is then shown OS/7's own GDM login screen over the
#     wire, where they sign in as themselves (M-R33). Windows has no equivalent
#     of the first secret, so OS/7 names it, generates it, and never prints it
#     by accident.
#
#   * THE ORDER, which is not taste. The daemon reads the credential at START
#     and ignores a later set-credentials (M-R28) — mstsc then fails with
#     0x904 — so Enable- goes cert -> key -> credential -> enable, and any
#     credential change restarts the unit. Without a certificate the daemon
#     runs and listens on NOTHING (M-R4); with a certificate and no credential
#     it listens and resets everyone (M-R5). "Enabled" is three different
#     questions and P6 is why they are three fields.
#
#   * THAT grdctl EXITS 0 HAVING DONE NOTHING. Unelevated, or with no TTY, every
#     set-* and enable returns 0 and writes nothing (M-R25); the README's
#     stdin form left the username EMPTY and still returned 0. So no cmdlet here
#     trusts an exit code: every write is READ BACK from `grdctl --system
#     status`, the unit and the socket. That is P5, and it is the whole reason
#     Invoke-OS7GrdCtl does not throw on a non-zero code the way
#     Invoke-OS7Native does — the code is not the answer.
#
#   * THAT stdout IS THE ONLY STREAM WORTH READING. Every grdctl call on a
#     machine whose TPM the daemon cannot open prints
#     "Init TPM credentials failed ... using GKeyFile as fallback" on stderr
#     (M-R13/M-R24). A parser that reads both streams reports a working machine
#     as broken.
#
# WHAT THIS FILE DELIBERATELY DOES NOT CONTAIN (docs/REMOTE-DESKTOP-PLAN.md §5):
# Add-/Remove-/Get-OS7RemoteDesktopUser — the per-user allow-list is enforced by
# a PAM rule on the remote GDM path whose service name and local-account
# fall-through are OWED (O-R2/O-R3), and a cmdlet that implied "this user can
# now connect" would be asserting the unmeasured thing. Get-/Disconnect-
# OS7RemoteDesktopSession — needs a logind verb the Systemd module does not
# export, and `loginctl` is a P2-systemd token.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

# The daemon's own configuration, which grdctl owns and OS/7 never hand-writes
# (R2: a paraphrased config is BUILD-NOTES #64/#66 — a listener on nothing).
$script:OS7RdpConfigPath = '/etc/gnome-remote-desktop/grd.conf'
$script:OS7RdpCtl        = '/usr/bin/grdctl'
$script:OS7RdpUnit       = 'gnome-remote-desktop.service'

# OS/7's own, and inside the boot environment on purpose (R8): a self-signed key
# nobody else trusts SHOULD roll back with the system. A CA-issued key clients
# have pinned is DECISIONS open question 9's shape and is flagged, not solved.
$script:OS7RdpStateDir   = '/etc/os7/remote-desktop'
$script:OS7RdpCertPath   = '/etc/os7/remote-desktop/tls.crt'
$script:OS7RdpKeyPath    = '/etc/os7/remote-desktop/tls.key'

# The service account the daemon runs as (its own package's sysusers entry).
$script:OS7RdpDaemonUser = 'gnome-remote-desktop'

# The machine-wide RDP credential's username. FIXED, and fixed on purpose: it
# is not a user account, and a name an operator could change would invite it to
# be read as one. R4.
$script:OS7RdpUserName   = 'os7-rdp'

$script:OS7RdpDefaultPort = 3389
$script:OS7RdpUfwProfile  = 'os7-remote-desktop'

# The test seam. Set inside the module's own scope by
# installer/testing/check-remotedesktop-logic.py; $null on every real machine.
# It is a SCRIPT variable and not a closure, because BUILD-NOTES #96 is what
# .GetNewClosure() does to a block that has to reach $script: state.
$script:OS7RdpCommandOverride = $null

# Where the served leaf lands during the TLS probe. A script variable because
# SslStream's validation callback is a delegate and this is the only scope both
# it and the caller can see.
$script:OS7RdpServedLeaf = $null

function Invoke-OS7GrdCtl {
	<#
	.SYNOPSIS
		Internal. Run grdctl and come back with BOTH streams and the code,
		without throwing on the code.

	.DESCRIPTION
		DELIBERATELY NOT Invoke-OS7Native, and the difference is the whole
		point: Invoke-OS7Native throws on a non-zero exit, and grdctl's exit
		code carries no information at all — it is 0 for a call that wrote
		nothing (M-R25). Every caller here reads the machine back instead.

		stdout and stderr are captured SEPARATELY because the TPM fallback line
		is on stderr on every OS/7 machine (M-R13/M-R24) and is not an error.
	#>
	param([Parameter(Mandatory)][string[]]$Arguments)

	if ($script:OS7RdpCommandOverride) {
		return & $script:OS7RdpCommandOverride $script:OS7RdpCtl $Arguments
	}

	$errFile = [System.IO.Path]::GetTempFileName()
	try {
		# BUILD-NOTES #121: reset, then read under the Test-Path guard. A
		# command that is found but cannot be started otherwise reads an
		# EARLIER command's exit code as its own.
		$global:LASTEXITCODE = $null
		$out = & $script:OS7RdpCtl @Arguments 2> $errFile
		$code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
		$err = (Get-Content -Raw -ErrorAction SilentlyContinue $errFile)
		return [pscustomobject]@{
			StdOut   = ($out -join "`n")
			StdErr   = if ($err) { $err.TrimEnd() } else { '' }
			ExitCode = $code
		}
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $errFile
	}
}

function Get-OS7RdpStatusText {
	<#
	.SYNOPSIS
		Internal. `grdctl --system status` as lines of stdout, or $null when
		grdctl could not be asked at all.

	.DESCRIPTION
		$null and an empty list are different answers and the callers depend on
		it: "grdctl is not on this machine" is Supported=$false, while "grdctl
		answered and said nothing is enabled" is Enabled=$false. Conflating
		them is the shape POWERSHELL-SURFACE-PLAN P6 and Get-OS7Remoting's
		SubsystemReason both exist to avoid.
	#>
	param([switch]$ShowCredentials)

	# NOT $args: that is an automatic variable, and assigning to it is
	# BUILD-NOTES #65's shape in a fresh file.
	$argv = @('--system', 'status')
	if ($ShowCredentials) { $argv += '--show-credentials' }

	try { $r = Invoke-OS7GrdCtl -Arguments $argv }
	catch { return $null }
	if ($null -eq $r) { return $null }
	# grdctl prints the whole status to stdout; a run that produced no stdout
	# at all did not answer, whatever the exit code was (M-R25).
	if ([string]::IsNullOrWhiteSpace($r.StdOut)) { return $null }
	return @($r.StdOut -split "`n")
}

function Get-OS7RdpStatusField {
	<#
	.SYNOPSIS
		Internal. One `Label: value` line out of grdctl's status block.
	#>
	param(
		[AllowNull()][string[]]$Lines,
		[Parameter(Mandatory)][string]$Label
	)
	if (-not $Lines) { return $null }
	foreach ($line in $Lines) {
		$t = $line.Trim()
		# "$Label:*" would parse `$Label:` as a scope qualifier; the subexpression
		# is the unambiguous spelling.
		if ($t -like "$($Label):*") {
			$v = $t.Substring($Label.Length + 1).Trim()
			# grdctl spells "unset" three ways depending on the field.
			if ($v -eq '(null)' -or $v -eq '(empty)' -or $v -eq '') { return '' }
			return $v
		}
	}
	return $null
}

function Test-OS7RdpSupported {
	<#
	.SYNOPSIS
		Internal. Is there a remote-desktop daemon on this machine at all?

	.DESCRIPTION
		amd64 GUI only, and that is not a policy here but a fact about the
		image: gnome-remote-desktop arrives behind ubuntu-desktop-minimal, the
		headless installer purges the whole desktop stack (M-R19) and arm64
		never had it. On those machines the answer is not "off", it is "not
		this product" — and Get- says Supported=$false rather than pretend.
	#>
	if ($script:OS7RdpCommandOverride) { return $true }
	return (Test-Path -LiteralPath $script:OS7RdpCtl)
}

function Get-OS7RdpListeningPort {
	<#
	.SYNOPSIS
		Internal. Is anything listening on this TCP port, and on which families?

	.DESCRIPTION
		ASKED OF THE KERNEL THROUGH .NET, not of `ss` — no external command, no
		parsing, and nothing for a layering rule to be about. It answers the
		EFFECTIVE half of P6's pair: a daemon can be `active/running` and be
		listening on nothing at all, which is exactly the state a missing
		certificate produces (M-R4).
	#>
	param([Parameter(Mandatory)][int]$Port)

	try {
		$props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
		$eps = @($props.GetActiveTcpListeners() | Where-Object { $_.Port -eq $Port })
	}
	catch {
		# A container without the netlink the API needs is "cannot tell".
		return $null
	}

	$v4 = @($eps | Where-Object { $_.AddressFamily -eq 'InterNetwork' }).Count -gt 0
	$v6 = @($eps | Where-Object { $_.AddressFamily -eq 'InterNetworkV6' }).Count -gt 0

	# A WILDCARD IPv6 SOCKET SERVES IPv4 TOO, and reporting otherwise would be
	# a field that says "no" about a client that connects. The daemon binds one
	# dual-stack socket - `ss` shows a single `*:3389` - so the kernel's listener
	# list has an IPv6 entry and no IPv4 one, while an IPv4 client reaches it
	# perfectly well (measured: FreeRDP connected over IPv4 to exactly this
	# listener). Linux dual-stacks a wildcard v6 bind unless net.ipv6.bindv6only
	# is set, so the honest answer is that v4 is served, and DualStack says how.
	$wildcardV6 = @($eps | Where-Object {
			$_.AddressFamily -eq 'InterNetworkV6' -and $_.Address.Equals([System.Net.IPAddress]::IPv6Any)
		}).Count -gt 0

	return [pscustomobject]@{
		Listening = ($v4 -or $v6)
		IPv4      = ($v4 -or $wildcardV6)
		IPv6      = $v6
		DualStack = $wildcardV6
	}
}

function Get-OS7RdpFirewallState {
	<#
	.SYNOPSIS
		Internal. Whether a host firewall is active on this machine.

	.DESCRIPTION
		READ FROM ufw's OWN CONFIGURATION FILE, not from `ufw status`, because
		the answer is wanted on a machine where ufw may not be runnable and the
		file is the thing ufw itself reads at boot. It is `Inactive` on every
		OS/7 machine measured (M-R22) — ufw and nftables are installed, nothing
		enables them, and DECISIONS open question 1 owns that. This cmdlet
		reports the state; it does not decide it (R9).
	#>
	$conf = '/etc/ufw/ufw.conf'
	if (-not (Test-Path -LiteralPath $conf)) { return 'None' }
	try {
		foreach ($line in [System.IO.File]::ReadAllLines($conf)) {
			if ($line -match '^\s*ENABLED\s*=\s*(\S+)') {
				return $(if ($Matches[1] -match '^(yes|true)$') { 'Active' } else { 'Inactive' })
			}
		}
	}
	catch { return $null }
	return 'Inactive'
}

function Get-OS7RdpFileFingerprint {
	<#
	.SYNOPSIS
		Internal. A PEM certificate's SHA-256 and SHA-1 fingerprints, colon-
		separated, lower case.

	.DESCRIPTION
		LOWER CASE AND COLON-SEPARATED because that is how `grdctl --system
		status` prints the SHA-256 (M-R3/M-R15), and a fingerprint an operator
		has to re-case before comparing is a fingerprint they will compare
		wrongly. The SHA-1 is carried beside it because the Windows certificate
		dialog is expected to show that one — inferred, not measured; the plan
		owes O-R9.
	#>
	param([Parameter(Mandatory)][string]$Path)

	if (-not (Test-Path -LiteralPath $Path)) { return $null }
	try {
		$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::
			CreateFromPemFile($Path)
	}
	catch {
		try {
			$cert = [System.Security.Cryptography.X509Certificates.X509CertificateLoader]::
				LoadCertificateFromFile($Path)
		}
		catch { return $null }
	}

	$der = $cert.RawData
	$sha256 = [System.Security.Cryptography.SHA256]::HashData($der)
	$sha1 = [System.Security.Cryptography.SHA1]::HashData($der)
	$fmt = { param($bytes) (($bytes | ForEach-Object { $_.ToString('x2') }) -join ':') }

	$san = ''
	foreach ($ext in $cert.Extensions) {
		if ($ext.Oid.Value -eq '2.5.29.17') { $san = $ext.Format($false) }
	}

	return [pscustomobject]@{
		Sha256     = (& $fmt $sha256)
		Sha1       = (& $fmt $sha1)
		Subject    = $cert.Subject
		Issuer     = $cert.Issuer
		NotAfter   = $cert.NotAfter
		NotBefore  = $cert.NotBefore
		SubjectAlternativeName = $san
	}
}

function Get-OS7RdpServedCertificate {
	<#
	.SYNOPSIS
		Internal. The certificate the DAEMON actually serves, fetched by
		speaking RDP to it.

	.DESCRIPTION
		BUILD-NOTES #111 IN A SECOND PLACE: ask the program that actually opens
		the file, not the tool that wrote it. `openssl x509` says what is in a
		file; only a connection says what the listener presents — and the two
		differ whenever grd.conf points at a path that has since been replaced,
		which is precisely what a boot-environment rollback can produce (R15).

		IT IS NOT A PLAIN TLS HANDSHAKE, and that is measured rather than
		assumed. RDP negotiates security in an X.224 Connection Request FIRST
		(MS-RDPBCGR 2.2.1.1); the daemon answers RDP_NEG_RSP selecting HYBRID
		and refuses TLS-only outright (M-R14). So this sends the Connection
		Request, reads the response, and only then starts TLS on the same
		socket.

		It authenticates NOTHING. The callback accepts any certificate on
		purpose: the question is "which certificate is this daemon serving",
		and refusing an untrusted one would make a self-signed default — the
		documented default — unaskable.

	.PARAMETER RequestedProtocols
		The X.224 requestedProtocols bitmask. 0x0f offers everything, which is
		what a real client does; 0x01 offers TLS only and is how Test- proves
		the server REFUSES a non-NLA client rather than assuming it.
	#>
	param(
		[int]$Port = $script:OS7RdpDefaultPort,
		[string]$TargetHost = '127.0.0.1',
		[int]$RequestedProtocols = 0x0f,
		[int]$TimeoutMs = 5000,
		[switch]$NegotiateOnly
	)

	$client = $null
	$ssl = $null
	$script:OS7RdpServedLeaf = $null
	try {
		$client = [System.Net.Sockets.TcpClient]::new()
		$connect = $client.ConnectAsync($TargetHost, $Port)
		if (-not $connect.Wait($TimeoutMs)) {
			return [pscustomobject]@{ Reached = $false; Reason = 'connect timed out' }
		}
		$client.ReceiveTimeout = $TimeoutMs
		$client.SendTimeout = $TimeoutMs
		$stream = $client.GetStream()

		# TPKT header + X.224 Connection Request + RDP_NEG_REQ. Nineteen bytes,
		# and the length field says so.
		$neg = [byte[]]@(0x01, 0x00, 0x08, 0x00) +
			[System.BitConverter]::GetBytes([uint32]$RequestedProtocols)
		$x224 = [byte[]]@(0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00) + $neg
		$total = 4 + $x224.Length
		$req = [byte[]]@(0x03, 0x00, [byte](($total -shr 8) -band 0xff), [byte]($total -band 0xff)) + $x224
		$stream.Write($req, 0, $req.Length)
		$stream.Flush()

		$buf = [byte[]]::new(64)
		$read = 0
		try { $read = $stream.Read($buf, 0, $buf.Length) }
		catch {
			return [pscustomobject]@{ Reached = $true; Negotiated = $false
				Reason = 'the server closed the connection without answering the negotiation' }
		}
		if ($read -lt 19) {
			return [pscustomobject]@{ Reached = $true; Negotiated = $false
				Reason = "the negotiation answer was $read bytes" }
		}

		$type = $buf[11]
		$selected = [System.BitConverter]::ToUInt32($buf, 15)
		if ($type -eq 0x03) {
			# RDP_NEG_FAILURE. 5 is HYBRID_REQUIRED_BY_SERVER, which is the
			# daemon insisting on NLA — a refusal that is a PASS for Test-.
			return [pscustomobject]@{
				Reached = $true; Negotiated = $false; Failure = [int]$selected
				Reason = "the server refused the offered security (RDP_NEG_FAILURE $selected)"
			}
		}
		if ($type -ne 0x02) {
			return [pscustomobject]@{ Reached = $true; Negotiated = $false
				Reason = "unexpected negotiation response type 0x$($type.ToString('x2'))" }
		}

		$result = [pscustomobject]@{
			Reached = $true; Negotiated = $true
			SelectedProtocol = [int]$selected
			RequiresNla = ([int]$selected -eq 2)
			Sha256 = $null; Subject = $null; Reason = $null
		}
		if ($NegotiateOnly) { return $result }

		$ssl = [System.Net.Security.SslStream]::new($stream, $false,
			[System.Net.Security.RemoteCertificateValidationCallback] {
				param($theSender, $certificate, $chain, $errors)
				$script:OS7RdpServedLeaf = $certificate
				return $true
			})
		$ssl.AuthenticateAsClient($TargetHost)

		if ($script:OS7RdpServedLeaf) {
			$der = $script:OS7RdpServedLeaf.GetRawCertData()
			$hash = [System.Security.Cryptography.SHA256]::HashData($der)
			$result.Sha256 = (($hash | ForEach-Object { $_.ToString('x2') }) -join ':')
			$result.Subject = $script:OS7RdpServedLeaf.Subject
		}
		return $result
	}
	catch {
		return [pscustomobject]@{ Reached = $false; Reason = $_.Exception.Message }
	}
	finally {
		if ($ssl) { $ssl.Dispose() }
		if ($client) { $client.Dispose() }
		$script:OS7RdpServedLeaf = $null
	}
}

function Get-OS7RemoteDesktop {
	<#
	.SYNOPSIS
		Whether this machine can be reached with Remote Desktop, and whether it
		actually would be.

	.DESCRIPTION
		THREE FIELDS, NEVER ONE, because "enabled" is three questions with
		three different answers and the interesting machine is the one where
		they disagree (P6):

		  Enabled     what grd.conf says — the CONFIGURED intent.
		  Running     whether the daemon is up — asked of systemd.
		  Listening   whether anything is on the port — asked of the kernel.

		A machine can be all three and still refuse every client, and that is
		not exotic: with a certificate and no machine credential the daemon
		listens and resets everyone (M-R5); with no certificate at all it runs
		and listens on nothing (M-R4). `CredentialSet` and
		`CertificatePresent` are why the answer is readable rather than a
		puzzle.

		`Supported` is `$false` on a machine with no daemon — headless amd64
		and every arm64 machine (M-R19). That is not "off"; it is a different
		product, and `Detail` says so rather than offering a switch that
		cannot work.

		A field that could not be asked is `$null`, NEVER `$false`. A check
		that did not run must not read as one that passed.

		THE CREDENTIAL IS NEVER A FIELD. `CredentialSet` is a boolean and that
		is all: P7 forbids a secret reaching an object that can be piped into
		ConvertTo-Json, a log or a screen. `Set-OS7RemoteDesktopCredential
		-Reveal` is the one deliberate act that surfaces it.

	.EXAMPLE
		Get-OS7RemoteDesktop | Format-List

	.EXAMPLE
		Get-OS7RemoteDesktop | Select-Object Enabled, Running, Listening, FirewallState
	#>
	[CmdletBinding()]
	param()

	$supported = Test-OS7RdpSupported
	if (-not $supported) {
		return [pscustomobject]@{
			PSTypeName        = 'OS7.RemoteDesktop'
			Supported         = $false
			Enabled           = $null
			Running           = $null
			Listening         = $null
			ListeningIPv4     = $null
			ListeningIPv6     = $null
			Port              = $null
			CertificatePresent = $null
			CertificatePath   = $null
			KeyPath           = $null
			FingerprintSha256 = $null
			FingerprintSha1   = $null
			CredentialSet     = $null
			CredentialUserName = $null
			AuthMethods       = $null
			FirewallState     = (Get-OS7RdpFirewallState)
			StatusReason      = 'gnome-remote-desktop is not installed'
			Detail            = 'this machine has no remote-desktop daemon: RDP is the amd64 GUI product only, and the remote path here is ssh (Get-OS7Remoting)'
		}
	}

	$lines = Get-OS7RdpStatusText
	$statusReason = $null
	if ($null -eq $lines) {
		$statusReason = 'grdctl could not be asked (it needs root: the polkit action is auth_admin)'
	}

	$status = Get-OS7RdpStatusField -Lines $lines -Label 'Status'
	$enabled = if ($null -eq $lines) { $null } else { $status -eq 'enabled' }

	$portText = Get-OS7RdpStatusField -Lines $lines -Label 'Port'
	$port = $script:OS7RdpDefaultPort
	if ($portText -and ($portText -as [int])) { $port = [int]$portText }

	$certPath = Get-OS7RdpStatusField -Lines $lines -Label 'TLS certificate'
	$keyPath = Get-OS7RdpStatusField -Lines $lines -Label 'TLS key'
	$fpr = Get-OS7RdpStatusField -Lines $lines -Label 'TLS fingerprint'
	$auth = Get-OS7RdpStatusField -Lines $lines -Label 'Authentication methods'

	# `(hidden)` when set, `(empty)` when not — measured on a booted machine,
	# and it is the readback that confirms a credential took WITHOUT revealing
	# it. `--show-credentials` is never used on this path (P7).
	$userText = Get-OS7RdpStatusField -Lines $lines -Label 'Username'
	$credentialSet = if ($null -eq $lines) { $null } else { -not [string]::IsNullOrEmpty($userText) }

	# THE UNIT IS NOT IN THE LIST UNTIL IT HAS BEEN LOADED, and on a machine
	# where Remote Desktop has never been turned on it never has been:
	# `Get-SystemdUnit` returned ZERO rows for it on a booted OS/7 machine
	# while the unit file was on disk all along. That is BUILD-NOTES #116's
	# shape in a third place - the same reason Get-SystemdTimer has to merge
	# two lists - and reporting $null for it would be wrong in the direction
	# that matters: "cannot tell" for a daemon that is certainly not running.
	#
	# So the three answers are kept apart. An exception is $null, because
	# systemd could not be asked at all. No rows AND a unit file on disk is
	# $false, because a unit systemd has not loaded is a unit that is not
	# running. No rows and no unit file is $null again, because then the
	# question is about a machine this cmdlet does not understand.
	$running = $null
	$runReason = $null
	try {
		Import-OS7SystemdLayer
		$unit = @(Get-SystemdUnit -Name $script:OS7RdpUnit) | Select-Object -First 1
		if ($unit) {
			$running = ($unit.ActiveState -eq 'active')
		}
		elseif (Test-Path -LiteralPath "/usr/lib/systemd/system/$($script:OS7RdpUnit)") {
			$running = $false
			$runReason = 'the unit is present and has never been loaded, which is what systemd reports for one that has never been started'
		}
		else {
			$runReason = 'systemd lists no such unit and no unit file is on disk'
		}
	}
	catch { $runReason = $_.Exception.Message }

	$listen = Get-OS7RdpListeningPort -Port $port

	$fileFpr = $null
	if ($certPath) { $fileFpr = Get-OS7RdpFileFingerprint -Path $certPath }

	$detail =
	if ($statusReason) { $statusReason }
	elseif (-not $enabled) { 'Remote Desktop is off; Enable-OS7RemoteDesktop turns it on' }
	elseif (-not $certPath) { 'enabled, but NO CERTIFICATE is configured — the daemon runs and listens on nothing' }
	elseif ($credentialSet -eq $false) { 'enabled with a certificate, but NO MACHINE CREDENTIAL — the port answers and refuses every client' }
	elseif ($listen -and -not $listen.Listening) { 'enabled and configured, but nothing is listening on the port' }
	elseif ($listen -and $listen.Listening) { "listening on $port; a client authenticates with the machine credential and then signs in at the OS/7 login screen" }
	else { 'enabled and configured' }

	return [pscustomobject]@{
		PSTypeName         = 'OS7.RemoteDesktop'
		Supported          = $true
		Enabled            = $enabled
		Running            = $running
		Listening          = if ($listen) { $listen.Listening } else { $null }
		ListeningIPv4      = if ($listen) { $listen.IPv4 } else { $null }
		ListeningIPv6      = if ($listen) { $listen.IPv6 } else { $null }
		ListeningDualStack = if ($listen) { $listen.DualStack } else { $null }
		Port               = $port
		CertificatePresent = if ($null -eq $lines) { $null } else { -not [string]::IsNullOrEmpty($certPath) }
		CertificatePath    = if ($certPath) { $certPath } else { $null }
		KeyPath            = if ($keyPath) { $keyPath } else { $null }
		FingerprintSha256  = if ($fpr) { $fpr } elseif ($fileFpr) { $fileFpr.Sha256 } else { $null }
		FingerprintSha1    = if ($fileFpr) { $fileFpr.Sha1 } else { $null }
		CredentialSet      = $credentialSet
		CredentialUserName = if ($credentialSet) { $script:OS7RdpUserName } else { $null }
		AuthMethods        = if ($auth) { $auth } else { $null }
		FirewallState      = (Get-OS7RdpFirewallState)
		RunningReason      = $runReason
		StatusReason       = $statusReason
		Detail             = $detail
	}
}

function New-OS7RemoteDesktopPassword {
	<#
	.SYNOPSIS
		Internal. A machine RDP credential, as a [securestring].

	.DESCRIPTION
		RandomNumberGenerator, not Get-Random: the latter is a deterministic
		PRNG seeded from the clock and is documented as unsuitable for
		security. GetInt32 over the alphabet rather than modulo a byte, so the
		distribution is uniform rather than nearly uniform.

		The alphabet excludes the characters that look like one another in a
		console font an operator is reading a secret out of (0/O, 1/l/I) —
		this string is typed into mstsc by a human exactly once, and a
		fingerprint of confusion there is a support call.
	#>
	param([int]$Length = 24)

	$alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
	$secure = [System.Security.SecureString]::new()
	for ($i = 0; $i -lt $Length; $i++) {
		$idx = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)
		$secure.AppendChar($alphabet[$idx])
	}
	$secure.MakeReadOnly()
	return $secure
}

function ConvertFrom-OS7RdpSecureString {
	<#
	.SYNOPSIS
		Internal. A [securestring] as plain text, for exactly as long as it
		takes to hand it to grdctl.

	.DESCRIPTION
		P7 says a secret is carried as a securestring and never serialised.
		Handing one to an external program means it becomes plain text
		somewhere, and the honest thing is to make that somewhere small,
		named, and freed rather than to pretend it does not happen.
	#>
	param([Parameter(Mandatory)][securestring]$Secure)

	$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secure)
	try { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
	finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}

function Set-OS7RdpCredentialValue {
	<#
	.SYNOPSIS
		Internal. Put the machine credential into the daemon, and prove it took.

	.DESCRIPTION
		TWO ROUTES, TRIED IN THE SAFE ORDER, because the measurement says the
		safe one does not always work. The README's stdin form keeps the
		secret off the command line and was measured returning 0 having left
		the username EMPTY (M-R25); the two-argument form was measured working
		and puts the secret in argv, where any local user can read it out of
		/proc for the milliseconds it lives there.

		So: stdin first, read back, and fall back to argv only if the daemon
		says nothing arrived. The readback is `Username:` reading `(hidden)`
		rather than `(empty)` — which confirms the write WITHOUT
		`--show-credentials` and therefore without the secret crossing a
		stream (P7).

		docs/REMOTE-DESKTOP-PLAN.md O-R13 owes the measurement that would let
		one of these two routes be deleted. Until then this reports which one
		worked rather than hiding it.
	#>
	param([Parameter(Mandatory)][securestring]$Password)

	$plain = ConvertFrom-OS7RdpSecureString -Secure $Password
	try {
		# Route 1 — the secret never reaches argv.
		if (-not $script:OS7RdpCommandOverride) {
			try {
				$psi = [System.Diagnostics.ProcessStartInfo]::new()
				$psi.FileName = $script:OS7RdpCtl
				foreach ($a in @('--system', 'rdp', 'set-credentials')) { $psi.ArgumentList.Add($a) }
				$psi.RedirectStandardInput = $true
				$psi.RedirectStandardOutput = $true
				$psi.RedirectStandardError = $true
				$psi.UseShellExecute = $false
				$proc = [System.Diagnostics.Process]::Start($psi)
				$proc.StandardInput.WriteLine($script:OS7RdpUserName)
				$proc.StandardInput.WriteLine($plain)
				$proc.StandardInput.Close()
				$null = $proc.StandardOutput.ReadToEnd()
				$null = $proc.StandardError.ReadToEnd()
				$proc.WaitForExit(10000) | Out-Null
			}
			catch {
				Write-OS7Step "the stdin credential route failed outright: $($_.Exception.Message)"
			}

			$lines = Get-OS7RdpStatusText
			$user = Get-OS7RdpStatusField -Lines $lines -Label 'Username'
			if (-not [string]::IsNullOrEmpty($user)) {
				Write-OS7Step 'machine credential set (stdin)'
				return 'stdin'
			}
			Write-OS7Step 'the stdin route left the credential unset (M-R25); using the argument form'
		}

		# Route 2 — measured to work, and the secret is briefly in argv.
		$null = Invoke-OS7GrdCtl -Arguments @('--system', 'rdp', 'set-credentials',
			$script:OS7RdpUserName, $plain)

		$lines = Get-OS7RdpStatusText
		$user = Get-OS7RdpStatusField -Lines $lines -Label 'Username'
		if ([string]::IsNullOrEmpty($user)) {
			throw [System.InvalidOperationException]::new(
				'grdctl accepted the credential and the daemon still reports none set. ' +
				'grdctl exits 0 having done nothing when it is not run as root ' +
				'(the polkit action is auth_admin) — run this elevated.')
		}
		Write-OS7Step 'machine credential set (argument form)'
		return 'argv'
	}
	finally {
		# The plain text is a .NET string and cannot be wiped; what can be done
		# is to stop referring to it. Named rather than pretended away.
		$plain = $null
	}
}

function New-OS7RemoteDesktopCertificate {
	<#
	.SYNOPSIS
		Generate the TLS certificate the RDP listener presents.

	.DESCRIPTION
		A SELF-SIGNED CERTIFICATE WITH THIS MACHINE'S NAME IN A SAN, which is
		better than what the desktop would do on its own: GNOME Settings issues
		`CN=GNOME` with no SAN at all, and Windows matches the name on the SAN
		rather than the CN — so a client is told the certificate belongs to
		something called GNOME. The subject and the SAN are this machine's
		host name and FQDN.

		THE KEY IS NEVER READABLE BY ANYONE ELSE, AT ANY INSTANT. The file is
		created empty at mode 0600 BEFORE openssl writes into it (P7's rule
		exactly: the mode goes on before the content, not after), because
		openssl preserves the mode of a file it truncates. It is then handed
		to the daemon's account as root:gnome-remote-desktop 0640 — the
		ownership the daemon was measured to accept. This matters more here
		than it reads: on the Windows authoring host every bind-mounted path
		presents as 0777 (BUILD-NOTES #117), so a "chmod afterwards" would be
		a window this repository has already been bitten through.

		It does NOT restart the daemon. The daemon reads the certificate path
		from its own configuration; changing the FILE under a running listener
		is what `Set-OS7RemoteDesktopCertificate` handles, and `Enable-` orders
		the whole sequence.

	.PARAMETER Days
		How long the certificate is valid. 825 by default — long enough not to
		make re-enabling an annual chore, and inside the 825-day ceiling public
		clients enforce.

	.PARAMETER Force
		Replace an existing certificate. Without it an existing pair is left
		alone, because regenerating one silently would invalidate a
		fingerprint an operator has already written down.

	.EXAMPLE
		New-OS7RemoteDesktopCertificate
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[int]$Days = 825,
		[switch]$Force
	)

	if ((Test-Path -LiteralPath $script:OS7RdpCertPath) -and -not $Force) {
		Write-OS7Step 'a certificate is already present; not replacing it (-Force to replace)'
		return Get-OS7RemoteDesktopCertificate
	}

	$fqdn = [System.Net.Dns]::GetHostName()
	try {
		$entry = [System.Net.Dns]::GetHostEntry($fqdn)
		if ($entry -and $entry.HostName) { $fqdn = $entry.HostName }
	}
	catch { }
	$short = $fqdn.Split('.')[0]

	if (-not $PSCmdlet.ShouldProcess($fqdn, 'issue a self-signed RDP certificate')) {
		return Get-OS7RemoteDesktopCertificate
	}

	if (-not (Test-Path -LiteralPath $script:OS7RdpStateDir)) {
		$null = New-Item -ItemType Directory -Force -Path $script:OS7RdpStateDir
	}
	# 0755: the daemon runs as its own account and has to traverse this to
	# reach the key. The key's own mode is what protects it.
	#
	# File::SetUnixFileMode AND NOT Directory's: [System.IO.Directory] has no
	# such method at all (measured in os7img:175 - it is chmod, and File's
	# overload takes any path including a directory). The spelling that reads
	# more correct fails at the first Enable- on a real machine, which is what
	# check-remotedesktop-logic.py caught.
	[System.IO.File]::SetUnixFileMode($script:OS7RdpStateDir,
		[System.IO.UnixFileMode]'UserRead,UserWrite,UserExecute,GroupRead,GroupExecute,OtherRead,OtherExecute')

	# THE MODE GOES ON BEFORE THE CONTENT. openssl truncates an existing file
	# and keeps its mode, so the private key is never world-readable, not even
	# for the instant between being written and being chmod-ed.
	[System.IO.File]::WriteAllText($script:OS7RdpKeyPath, '')
	[System.IO.File]::SetUnixFileMode($script:OS7RdpKeyPath,
		[System.IO.UnixFileMode]'UserRead,UserWrite')

	$san = if ($short -eq $fqdn) { "DNS:$fqdn" } else { "DNS:$fqdn,DNS:$short" }
	$null = Invoke-OS7Native -Command 'openssl' -Arguments @(
		'req', '-x509', '-newkey', 'rsa:4096', '-noenc',
		'-keyout', $script:OS7RdpKeyPath,
		'-out', $script:OS7RdpCertPath,
		'-days', "$Days",
		'-subj', "/CN=$fqdn",
		'-addext', "subjectAltName=$san",
		'-addext', 'extendedKeyUsage=serverAuth')

	# The daemon's account must read the key; nobody else may.
	$null = Invoke-OS7Native -Command 'chown' -Arguments @(
		"root:$($script:OS7RdpDaemonUser)", $script:OS7RdpKeyPath, $script:OS7RdpCertPath)
	[System.IO.File]::SetUnixFileMode($script:OS7RdpKeyPath,
		[System.IO.UnixFileMode]'UserRead,UserWrite,GroupRead')
	[System.IO.File]::SetUnixFileMode($script:OS7RdpCertPath,
		[System.IO.UnixFileMode]'UserRead,UserWrite,GroupRead,OtherRead')

	Write-OS7Step "issued a self-signed RDP certificate for $fqdn"
	return Get-OS7RemoteDesktopCertificate
}

function Get-OS7RemoteDesktopCertificate {
	<#
	.SYNOPSIS
		The certificate this machine presents to a Remote Desktop client — the
		one on disk, and the one the daemon is actually serving.

	.DESCRIPTION
		TWO ANSWERS, BECAUSE THEY CAN DIFFER. `Sha256` is the file grd.conf
		points at; `ServedSha256` is what the listener presented when this
		cmdlet spoke RDP to it. They disagree when the daemon was not restarted
		after a certificate change, and after a boot-environment rollback that
		restored a different file under a running listener (R15) — the case a
		reader of the file alone cannot see. `Agrees` is the comparison, and it
		is `$null` when the daemon could not be reached rather than `$false`.

		The SHA-256 is the fingerprint `grdctl` prints and the one to compare.
		The SHA-1 is carried because the Windows certificate dialog is expected
		to show that one — inferred from Microsoft's dialog, not measured
		here; the plan owes that measurement.

	.EXAMPLE
		Get-OS7RemoteDesktopCertificate | Format-List
	#>
	[CmdletBinding()]
	param([int]$Port = 0)

	$lines = Get-OS7RdpStatusText
	$configured = Get-OS7RdpStatusField -Lines $lines -Label 'TLS certificate'
	$path = if ($configured) { $configured } else { $script:OS7RdpCertPath }

	if ($Port -le 0) {
		$portText = Get-OS7RdpStatusField -Lines $lines -Label 'Port'
		$Port = if ($portText -and ($portText -as [int])) { [int]$portText } else { $script:OS7RdpDefaultPort }
	}

	$file = Get-OS7RdpFileFingerprint -Path $path

	$served = $null
	$servedReason = $null
	$listen = Get-OS7RdpListeningPort -Port $Port
	if ($listen -and $listen.Listening) {
		$probe = Get-OS7RdpServedCertificate -Port $Port
		if ($probe.Reached -and $probe.PSObject.Properties.Name -contains 'Sha256' -and $probe.Sha256) {
			$served = $probe.Sha256
		}
		else { $servedReason = $probe.Reason }
	}
	else { $servedReason = 'nothing is listening on the port' }

	$agrees = $null
	if ($served -and $file) { $agrees = ($served -eq $file.Sha256) }

	return [pscustomobject]@{
		PSTypeName   = 'OS7.RemoteDesktopCertificate'
		Path         = $path
		KeyPath      = $script:OS7RdpKeyPath
		Present      = ($null -ne $file)
		Subject      = if ($file) { $file.Subject } else { $null }
		Issuer       = if ($file) { $file.Issuer } else { $null }
		SubjectAlternativeName = if ($file) { $file.SubjectAlternativeName } else { $null }
		NotBefore    = if ($file) { $file.NotBefore } else { $null }
		NotAfter     = if ($file) { $file.NotAfter } else { $null }
		Expired      = if ($file) { $file.NotAfter -lt (Get-Date) } else { $null }
		Sha256       = if ($file) { $file.Sha256 } else { $null }
		Sha1         = if ($file) { $file.Sha1 } else { $null }
		ServedSha256 = $served
		ServedReason = $servedReason
		Agrees       = $agrees
	}
}

function Set-OS7RemoteDesktopCertificate {
	<#
	.SYNOPSIS
		Use a certificate and key of your own — one issued by an enterprise CA.

	.DESCRIPTION
		The PEM pair is the Linux idiom and what the daemon takes: it stores
		PATHS, not copies (measured), so the files must stay where they are
		put. A Windows administrator's PFX habit has no verb here yet.

		IT VALIDATES BEFORE IT POINTS THE DAEMON AT ANYTHING. A certificate the
		loader cannot parse would otherwise become a listener that binds
		nothing, reported by a cmdlet that said it succeeded — the shape of
		BUILD-NOTES #64. The key is re-owned to the daemon's account the same
		way `New-` does it.

		IT RESTARTS THE DAEMON, and says so: the running listener holds the old
		certificate until it does, and a restart drops live connections
		(M-R28's shape).

	.PARAMETER CertPath
		The PEM certificate. Copied into /etc/os7/remote-desktop unless
		-InPlace is given.

	.PARAMETER KeyPath
		The PEM private key.

	.PARAMETER InPlace
		Point the daemon at the files where they are, instead of copying them
		into OS/7's own directory.

	.EXAMPLE
		Set-OS7RemoteDesktopCertificate -CertPath ./host.crt -KeyPath ./host.key
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory)][string]$CertPath,
		[Parameter(Mandatory)][string]$KeyPath,
		[switch]$InPlace
	)

	if (-not (Test-Path -LiteralPath $CertPath)) {
		throw [System.IO.FileNotFoundException]::new("no certificate at $CertPath")
	}
	if (-not (Test-Path -LiteralPath $KeyPath)) {
		throw [System.IO.FileNotFoundException]::new("no key at $KeyPath")
	}
	# Parsed by the loader BEFORE the daemon is pointed at it.
	$probe = Get-OS7RdpFileFingerprint -Path $CertPath
	if (-not $probe) {
		throw [System.InvalidOperationException]::new(
			"$CertPath is not a certificate this machine can parse; the daemon would " +
			'listen on nothing and report no error.')
	}

	if (-not $PSCmdlet.ShouldProcess($script:OS7RdpUnit, "use the certificate $($probe.Subject)")) {
		return Get-OS7RemoteDesktopCertificate
	}

	$targetCert = $CertPath
	$targetKey = $KeyPath
	if (-not $InPlace) {
		if (-not (Test-Path -LiteralPath $script:OS7RdpStateDir)) {
			$null = New-Item -ItemType Directory -Force -Path $script:OS7RdpStateDir
		}
		$targetCert = $script:OS7RdpCertPath
		$targetKey = $script:OS7RdpKeyPath
		# Mode before content, again (P7).
		[System.IO.File]::WriteAllText($targetKey, '')
		[System.IO.File]::SetUnixFileMode($targetKey, [System.IO.UnixFileMode]'UserRead,UserWrite')
		[System.IO.File]::WriteAllBytes($targetKey, [System.IO.File]::ReadAllBytes($KeyPath))
		[System.IO.File]::WriteAllBytes($targetCert, [System.IO.File]::ReadAllBytes($CertPath))
	}

	$null = Invoke-OS7Native -Command 'chown' -Arguments @(
		"root:$($script:OS7RdpDaemonUser)", $targetKey, $targetCert)
	[System.IO.File]::SetUnixFileMode($targetKey,
		[System.IO.UnixFileMode]'UserRead,UserWrite,GroupRead')
	[System.IO.File]::SetUnixFileMode($targetCert,
		[System.IO.UnixFileMode]'UserRead,UserWrite,GroupRead,OtherRead')

	$null = Invoke-OS7GrdCtl -Arguments @('--system', 'rdp', 'set-tls-cert', $targetCert)
	$null = Invoke-OS7GrdCtl -Arguments @('--system', 'rdp', 'set-tls-key', $targetKey)

	# Ask the daemon, not grdctl's exit code (M-R25).
	$lines = Get-OS7RdpStatusText
	$now = Get-OS7RdpStatusField -Lines $lines -Label 'TLS certificate'
	if ($now -ne $targetCert) {
		throw [System.InvalidOperationException]::new(
			"grdctl returned success and the daemon still reports '$now' as its certificate. " +
			'grdctl exits 0 having done nothing unless it is run as root.')
	}

	try {
		Import-OS7SystemdLayer
		Write-OS7Step 'restarting the remote-desktop daemon: it holds the old certificate until then, and this drops live connections'
		$null = Restart-SystemdUnit -Name $script:OS7RdpUnit -Confirm:$false
	}
	catch { Write-OS7Step "restarting the daemon failed: $($_.Exception.Message)" }

	return Get-OS7RemoteDesktopCertificate
}

function Set-OS7RemoteDesktopCredential {
	<#
	.SYNOPSIS
		Rotate, or deliberately reveal, the machine-wide Remote Desktop
		credential.

	.DESCRIPTION
		THIS IS NOT A USER ACCOUNT. It is the machine's front-door secret,
		checked by NLA before any screen exists, and every client uses the same
		one. Whoever holds it can reach the OS/7 login screen; they still have
		to sign in there as a person. Windows has no equivalent, which is why
		it has a name of its own here — the username is fixed to `os7-rdp` so
		nobody mistakes it for somebody's account.

		THE SECRET IS NOT PRINTED UNLESS YOU ASK. `Enable-OS7RemoteDesktop`
		never emits it on any stream (which is what makes the unattended path
		safe: an Intune script's captured output must not contain it), and
		`Get-OS7RemoteDesktop` reports only whether one is set. `-Reveal` is
		the deliberate act, and it returns a [pscredential] rather than a
		string so that it does not land in a transcript by accident.

		ROTATING RESTARTS THE DAEMON, because the daemon reads the credential
		at start and ignores a later change (M-R28) — a rotation without the
		restart is a machine still accepting the old secret. The restart drops
		live connections and this says so rather than being quietly
		disruptive.

	.PARAMETER Rotate
		Generate and install a new secret.

	.PARAMETER Reveal
		Return the credential so it can be typed into a client once.

	.EXAMPLE
		Set-OS7RemoteDesktopCredential -Reveal

	.EXAMPLE
		Set-OS7RemoteDesktopCredential -Rotate -Reveal
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[switch]$Rotate,
		[switch]$Reveal
	)

	if (-not $Rotate -and -not $Reveal) {
		throw [System.ArgumentException]::new(
			'nothing to do: -Rotate installs a new machine credential, -Reveal returns the current one.')
	}
	if (-not (Test-OS7RdpSupported)) {
		throw [System.InvalidOperationException]::new(
			'this machine has no remote-desktop daemon (RDP is the amd64 GUI product only).')
	}

	if ($Rotate) {
		if (-not $PSCmdlet.ShouldProcess($script:OS7RdpUnit,
				'install a new machine Remote Desktop credential and restart the daemon (this drops live connections)')) {
			return
		}
		$secure = New-OS7RemoteDesktopPassword
		$null = Set-OS7RdpCredentialValue -Password $secure

		try {
			Import-OS7SystemdLayer
			$unit = Get-SystemdUnit -Name $script:OS7RdpUnit | Select-Object -First 1
			if ($unit -and $unit.ActiveState -eq 'active') {
				Write-OS7Step 'restarting the daemon so the new credential takes effect (M-R28); live connections drop'
				$null = Restart-SystemdUnit -Name $script:OS7RdpUnit -Confirm:$false
			}
		}
		catch { Write-OS7Step "restarting the daemon failed: $($_.Exception.Message)" }

		if ($Reveal) {
			return [pscredential]::new($script:OS7RdpUserName, $secure)
		}
		Write-OS7Step 'the new credential was not printed; -Reveal returns it'
		return
	}

	# -Reveal alone: read what is set. This is the ONE path that asks grdctl
	# for the plaintext, and it exists because the secret has to be typed into
	# a client exactly once.
	if (-not $PSCmdlet.ShouldProcess('the machine Remote Desktop credential', 'reveal')) { return }

	$lines = Get-OS7RdpStatusText -ShowCredentials
	if ($null -eq $lines) {
		throw [System.InvalidOperationException]::new(
			'grdctl could not be asked — it needs root (the polkit action is auth_admin).')
	}
	$pw = Get-OS7RdpStatusField -Lines $lines -Label 'Password'
	$user = Get-OS7RdpStatusField -Lines $lines -Label 'Username'
	if ([string]::IsNullOrEmpty($pw)) {
		throw [System.InvalidOperationException]::new(
			'no machine credential is set. Enable-OS7RemoteDesktop sets one; -Rotate replaces it.')
	}
	$secure = [System.Security.SecureString]::new()
	foreach ($ch in $pw.ToCharArray()) { $secure.AppendChar($ch) }
	$secure.MakeReadOnly()
	return [pscredential]::new($(if ($user) { $user } else { $script:OS7RdpUserName }), $secure)
}

function Enable-OS7RemoteDesktop {
	<#
	.SYNOPSIS
		Turn Remote Desktop on, so this machine can be reached with mstsc.

	.DESCRIPTION
		ONE SWITCH FOR WHAT IS FOUR STEPS, IN THE ONE ORDER THAT WORKS. The
		daemon reads its certificate and its credential at START (M-R28), so
		this issues a certificate if there is none, installs a machine
		credential if there is none, and only then enables the backend —
		cert, key, credential, enable. In the other order the machine comes up
		listening and refusing every client, and mstsc reports 0x904 with
		nothing on the machine saying why.

		A SOURCE SCOPE IS REQUIRED, and this is the one place this cmdlet is
		deliberately awkward. RDP on a machine reachable from everywhere is
		online password guessing against a machine-wide secret that has no
		lockout: v1 ships no per-user allow-list and no faillock (the PAM work
		is owed), so the port's only defences are the strength of the
		credential and where it can be reached from. `-AllowFrom` names the
		networks that should reach it. `-AllowAnySource` is how an operator
		says out loud that they mean everywhere.

		NO FIREWALL IS ENABLED BY THIS CMDLET. No host firewall is active on
		OS/7 at all and no firewall cmdlets exist yet — that is a product
		question this feature does not get to decide (DECISIONS open question
		1). Where a firewall IS active, the scoped rule is applied; where it is
		not, the exact rule to apply by hand is printed. Nothing here runs
		`ufw enable`.

		IT ANSWERS FROM THE MACHINE. grdctl exits 0 having done nothing when it
		is not root (M-R25), so every step is read back — the daemon's own
		status, the unit, and the socket — and the returned object is
		`Get-OS7RemoteDesktop`, not a claim.

		THE CREDENTIAL IS NEVER PRINTED. Not on stdout, not in a warning, not
		under -Verbose: this cmdlet is the one an Intune script runs, and
		Intune captures script output. `Set-OS7RemoteDesktopCredential -Reveal`
		is the deliberate act that surfaces it.

	.PARAMETER AllowFrom
		The networks that may reach the port, in CIDR form.

	.PARAMETER AllowAnySource
		Accept that the port will be reachable from everywhere the network
		allows. Required when -AllowFrom is not given.

	.PARAMETER Port
		The TCP port to listen on. 3389 by default, which is what a client
		assumes.

	.EXAMPLE
		Enable-OS7RemoteDesktop -AllowFrom 10.0.0.0/24

	.EXAMPLE
		Enable-OS7RemoteDesktop -AllowAnySource -Confirm:$false
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[string[]]$AllowFrom,
		[switch]$AllowAnySource,
		[int]$Port = 0
	)

	if (-not (Test-OS7RdpSupported)) {
		throw [System.InvalidOperationException]::new(
			'this machine has no remote-desktop daemon. RDP is the amd64 GUI product only: ' +
			'headless installs purge the desktop stack and arm64 never had it. ' +
			'The remote path here is ssh — see Get-OS7Remoting.')
	}

	if (-not $AllowFrom -and -not $AllowAnySource) {
		throw [System.ArgumentException]::new(
			'refusing to open Remote Desktop without a source scope. This machine has no ' +
			'per-user allow-list and no account lockout on the Remote Desktop path yet, so ' +
			'the port is an unthrottled login prompt for anyone who can reach it. ' +
			'Pass -AllowFrom <CIDR> to name the networks that should, or -AllowAnySource ' +
			'to accept that it is reachable from everywhere the network allows.')
	}

	if (-not $PSCmdlet.ShouldProcess($script:OS7RdpUnit, 'enable Remote Desktop (RDP) on this machine')) {
		return Get-OS7RemoteDesktop
	}

	# 1 and 2 — the certificate and its key. Without them the daemon runs and
	# listens on nothing (M-R4).
	if (-not (Test-Path -LiteralPath $script:OS7RdpCertPath)) {
		$null = New-OS7RemoteDesktopCertificate -Confirm:$false
	}
	$null = Invoke-OS7GrdCtl -Arguments @('--system', 'rdp', 'set-tls-cert', $script:OS7RdpCertPath)
	$null = Invoke-OS7GrdCtl -Arguments @('--system', 'rdp', 'set-tls-key', $script:OS7RdpKeyPath)

	$lines = Get-OS7RdpStatusText
	if ($null -eq $lines) {
		throw [System.InvalidOperationException]::new(
			'grdctl could not be asked. It needs root: its polkit action is auth_admin, and ' +
			'unelevated it returns success having written nothing.')
	}
	$certNow = Get-OS7RdpStatusField -Lines $lines -Label 'TLS certificate'
	if ([string]::IsNullOrEmpty($certNow)) {
		throw [System.InvalidOperationException]::new(
			'the daemon reports no certificate after one was set. grdctl exits 0 having ' +
			'done nothing unless it is run as root (its polkit action is auth_admin), and ' +
			'that is the usual cause. Without a certificate the daemon runs and listens on ' +
			'nothing, so this would have looked enabled and been unreachable.')
	}

	# 3 — the machine credential. Without it the port answers and resets every
	# client (M-R5).
	$userNow = Get-OS7RdpStatusField -Lines $lines -Label 'Username'
	$issued = $false
	if ([string]::IsNullOrEmpty($userNow)) {
		$secure = New-OS7RemoteDesktopPassword
		$null = Set-OS7RdpCredentialValue -Password $secure
		$issued = $true
		$secure = $null
	}

	if ($Port -gt 0 -and $Port -ne $script:OS7RdpDefaultPort) {
		$null = Invoke-OS7GrdCtl -Arguments @('--system', 'rdp', 'set-port', "$Port")
	}

	# 4 — and only now. grdctl's own enable also enables and starts the unit
	# (M-R1); that is the vendor tool doing vendor work.
	$null = Invoke-OS7GrdCtl -Arguments @('--system', 'rdp', 'enable')

	# The firewall, which this cmdlet reports on and does not decide (R9).
	$fw = Get-OS7RdpFirewallState
	$effectivePort = if ($Port -gt 0) { $Port } else { $script:OS7RdpDefaultPort }
	if ($AllowFrom) {
		if ($fw -eq 'Active') {
			foreach ($cidr in $AllowFrom) {
				try {
					$null = Invoke-OS7Native -Command 'ufw' -Arguments @(
						'allow', 'from', $cidr, 'to', 'any', 'port', "$effectivePort", 'proto', 'tcp')
				}
				catch { Write-OS7Step "the firewall rule for $cidr was not applied: $($_.Exception.Message)" }
			}
		}
		else {
			Write-OS7Step "no host firewall is active, so -AllowFrom cannot be enforced. Apply by hand:"
			foreach ($cidr in $AllowFrom) {
				Write-OS7Step "  ufw allow from $cidr to any port $effectivePort proto tcp"
			}
		}
	}
	else {
		Write-OS7Step "Remote Desktop is reachable from every network this machine is on: -AllowAnySource was given."
	}

	if ($issued) {
		Write-OS7Step 'a machine Remote Desktop credential was generated and NOT printed. Run Set-OS7RemoteDesktopCredential -Reveal to read it once.'
	}

	return Get-OS7RemoteDesktop
}

function Disable-OS7RemoteDesktop {
	<#
	.SYNOPSIS
		Turn Remote Desktop off.

	.DESCRIPTION
		Sets the backend disabled and stops the daemon, which returns the
		machine to what a fresh install is.

		IT CLEARS THE MACHINE CREDENTIAL, and that is a decision rather than
		tidiness: a disabled machine that keeps its front-door secret is a
		machine where turning RDP back on silently re-opens the old door, and
		the secret rests in plaintext on disk until something removes it.
		`-KeepCredential` is for the operator who is turning the service off
		for an hour and does not want to redistribute a key.

		THE CERTIFICATE IS LEFT ALONE. It is this machine's identity, an
		operator may have recorded its fingerprint, and re-enabling should not
		hand every client a new one to accept.

		IT DIVERGES FROM WINDOWS AND SAYS SO: on Windows, disabling Remote
		Desktop refuses new connections and leaves existing ones alone.
		Stopping this daemon drops the transport of every live connection.
		There is no gentler path in the tool, so it is named rather than
		hidden behind a switch that would not work.

	.PARAMETER KeepCredential
		Leave the machine credential installed.

	.EXAMPLE
		Disable-OS7RemoteDesktop
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([switch]$KeepCredential)

	if (-not (Test-OS7RdpSupported)) { return Get-OS7RemoteDesktop }

	if (-not $PSCmdlet.ShouldProcess($script:OS7RdpUnit,
			'disable Remote Desktop (this drops every live connection)')) {
		return Get-OS7RemoteDesktop
	}

	$null = Invoke-OS7GrdCtl -Arguments @('--system', 'rdp', 'disable')
	if (-not $KeepCredential) {
		$null = Invoke-OS7GrdCtl -Arguments @('--system', 'rdp', 'clear-credentials')
	}

	# Asked of the daemon, not of grdctl's exit code.
	$lines = Get-OS7RdpStatusText
	$status = Get-OS7RdpStatusField -Lines $lines -Label 'Status'
	if ($lines -and $status -eq 'enabled') {
		throw [System.InvalidOperationException]::new(
			'grdctl returned success and the daemon still reports RDP enabled. ' +
			'It exits 0 having done nothing unless it is run as root.')
	}

	return Get-OS7RemoteDesktop
}

function Test-OS7RemoteDesktop {
	<#
	.SYNOPSIS
		Check the Remote Desktop configuration on this machine, one question at
		a time.

	.DESCRIPTION
		A LOCAL ORACLE, AND IT SAYS WHAT IT CANNOT ANSWER. It does not prove
		that anybody can log in: that needs a client, a person and a password,
		and no cmdlet on the machine can stand in for it. What it does is ask
		the machine the questions whose wrong answers produce a listener
		nobody can use:

		  * is there a daemon here at all;
		  * is the certificate present, parseable and unexpired, and does its
		    SAN carry this machine's name — Windows matches on the SAN;
		  * is the private key unreadable by anyone but root and the daemon;
		  * is a machine credential set;
		  * is something listening on the port;
		  * IS THE CERTIFICATE THE DAEMON SERVES THE ONE ON DISK — asked by
		    speaking RDP to the listener, which is the only way to tell (#111);
		  * DOES THE SERVER REFUSE A NON-NLA CLIENT — asked by offering TLS
		    alone and requiring the refusal. A server that accepted it would be
		    one where the machine credential is checked after a session
		    exists instead of before.

		Every result is `$true`, `$false`, or `$null` for a question that could
		not be asked — never `$true` for one that was skipped.

	.EXAMPLE
		Test-OS7RemoteDesktop | Format-Table Check, Result, Detail
	#>
	[CmdletBinding()]
	param()

	$results = [System.Collections.Generic.List[object]]::new()
	$add = {
		param($check, $result, $detail)
		$results.Add([pscustomobject]@{
				PSTypeName = 'OS7.RemoteDesktopCheck'
				Check      = $check
				Result     = $result
				Detail     = $detail
			})
	}

	if (-not (Test-OS7RdpSupported)) {
		& $add 'daemon present' $false 'gnome-remote-desktop is not installed: RDP is the amd64 GUI product only'
		return $results
	}
	& $add 'daemon present' $true $script:OS7RdpCtl

	$state = Get-OS7RemoteDesktop
	& $add 'enabled' $state.Enabled $state.Detail
	& $add 'daemon running' $state.Running $(if ($state.RunningReason) { $state.RunningReason } else { $script:OS7RdpUnit })
	& $add 'credential set' $state.CredentialSet $(if ($state.CredentialSet) { "username $($state.CredentialUserName)" } else { 'no machine credential: the port would refuse every client' })

	$cert = Get-OS7RemoteDesktopCertificate
	& $add 'certificate present' $cert.Present $cert.Path
	if ($cert.Present) {
		& $add 'certificate unexpired' (-not $cert.Expired) "valid to $($cert.NotAfter)"
		$fqdn = [System.Net.Dns]::GetHostName()
		$sanOk = $null
		if ($cert.SubjectAlternativeName) {
			$sanOk = ($cert.SubjectAlternativeName -like "*$fqdn*")
		}
		& $add 'certificate names this machine' $sanOk $(
			if ($cert.SubjectAlternativeName) { $cert.SubjectAlternativeName }
			else { 'no subjectAltName: Windows matches the name on the SAN, so a client will warn' })
	}

	if (Test-Path -LiteralPath $script:OS7RdpKeyPath) {
		$mode = [System.IO.File]::GetUnixFileMode($script:OS7RdpKeyPath)
		# Cast to int: an enum flag test left as an enum is truthy/falsy by
		# accident rather than by statement.
		$leaked = ([int]($mode -band [System.IO.UnixFileMode]::OtherRead) -ne 0) -or
		([int]($mode -band [System.IO.UnixFileMode]::OtherWrite) -ne 0)
		& $add 'private key not world-readable' (-not $leaked) "mode $mode"
	}
	else {
		& $add 'private key not world-readable' $null "no key at $($script:OS7RdpKeyPath)"
	}

	$listening = $state.Listening
	& $add 'listening on the port' $listening "port $($state.Port)"

	if ($listening) {
		& $add 'the daemon serves the configured certificate' $cert.Agrees $(
			if ($null -eq $cert.Agrees) { $cert.ServedReason }
			elseif ($cert.Agrees) { 'the served leaf matches the file' }
			else { "the daemon is serving $($cert.ServedSha256), the file is $($cert.Sha256) — it has not been restarted since the certificate changed" })

		$nla = Get-OS7RdpServedCertificate -Port $state.Port -RequestedProtocols 0x0f -NegotiateOnly
		& $add 'network level authentication negotiated' $(
			if ($nla.Reached -and $nla.PSObject.Properties.Name -contains 'RequiresNla') { $nla.RequiresNla } else { $null }
		) $(if ($nla.Reason) { $nla.Reason } else { "selected protocol $($nla.SelectedProtocol)" })

		# Offer TLS alone and REQUIRE the refusal. A pass here is a refusal.
		$tlsOnly = Get-OS7RdpServedCertificate -Port $state.Port -RequestedProtocols 0x01 -NegotiateOnly
		$refused = $null
		if ($tlsOnly.Reached) {
			$refused = (-not $tlsOnly.Negotiated)
		}
		& $add 'a client without NLA is refused' $refused $(
			if ($tlsOnly.Reason) { $tlsOnly.Reason } else { 'the server accepted a non-NLA client' })
	}

	$fw = Get-OS7RdpFirewallState
	& $add 'host firewall active' $(if ($fw -eq 'Active') { $true } elseif ($null -eq $fw) { $null } else { $false }) $(
		"$fw — no firewall ships enabled on OS/7 (DECISIONS open question 1); the port's scope is whatever the network allows")

	return $results
}
