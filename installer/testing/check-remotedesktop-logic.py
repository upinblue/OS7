#!/usr/bin/env python3
"""
The Remote Desktop DECISIONS, in seconds, with no daemon and no VM.

    ./check-remotedesktop-logic.py
    ./check-remotedesktop-logic.py --container os7img:175   # + the Unix-mode half

WHY IT EXISTS. docs/REMOTE-DESKTOP-PLAN.md turns a daemon the amd64 GUI image
already ships into a feature, and the measurements that shaped it are the kind
a cmdlet can quietly stop honouring:

  * `grdctl` EXITS 0 HAVING DONE NOTHING when it is not root (M-R25) — so a
    cmdlet that trusts an exit code reports a machine as configured that is
    not. Every write here must be READ BACK.
  * THE DAEMON READS ITS CERTIFICATE AND CREDENTIAL AT START (M-R28). Enable-
    must go cert -> key -> credential -> enable; in any other order the machine
    comes up listening and refusing every client, and mstsc says 0x904 with
    nothing on the machine explaining it.
  * WITHOUT A CERTIFICATE the daemon runs and listens on NOTHING (M-R4); with
    a certificate and no credential it listens and resets everyone (M-R5). So
    "enabled" is three fields, not one (P6), and a field nobody could ask must
    be $null and never $false.
  * THE MACHINE CREDENTIAL MUST NOT REACH A STREAM. Enable- is the cmdlet an
    Intune script runs, and Intune captures script output — a secret in that
    log is the secret published to the tenant (P7, R16).
  * ENABLING WITHOUT A SOURCE SCOPE IS THE EXPOSURE the plan refuses to ship
    quietly: v1 has no per-user allow-list and no lockout, so `-AllowFrom` or
    an explicit `-AllowAnySource` is a precondition, not a nicety (R9).

The status text the fake answers with is grdctl 50.2's REAL format, recorded
from a booted OS/7 machine and from os7img:175 on 2026-09-05 — including the
`(hidden)` / `(empty)` spelling that is the whole readback mechanism, and the
TPM fallback line grdctl prints on stderr on every OS/7 machine (M-R13/M-R24),
which a parser reading both streams would mistake for an error.

WHAT THIS IS NOT. It does not prove anybody can connect: that needs a client, a
person and a password (Tier 3, and the plan's O-R2). It checks what OS/7's layer
DECIDES and what it REFUSES.

The Unix-mode assertions — that the private key is never group- or
other-readable at any instant of its generation — need a real Linux filesystem.
They run natively on Linux, and with --container on any host that has docker and
an os7img:* image. On Windows without --container they are reported NOT CHECKED
rather than skipped, the check-netplan-rule.py rule: a check that did not run
must never read as one that passed.
"""
import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

FAILS = []
NOTCHECKED = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


def not_checked(what, why):
    print(f"      NOTE  NOT CHECKED: {what}   [{why}]")
    NOTCHECKED.append(what)


# The driver runs as a FILE with parameters rather than a formatted -Command
# string: it carries scriptblocks, and a brace lost to doubled-brace formatting
# is a fake that lies.
DRIVER = r"""
param(
    [Parameter(Mandatory)][string]$OS7Manifest,
    [Parameter(Mandatory)][string]$Lab
)
$ErrorActionPreference = 'Stop'
Import-Module $OS7Manifest -Force

# A certificate the loader can really parse. Generated with openssl when there
# is one, because a canned blob would go stale against the parser that reads it.
$certPath = Join-Path $Lab 'tls.crt'
$keyPath  = Join-Path $Lab 'tls.key'
$haveOpenssl = [bool](Get-Command openssl -ErrorAction SilentlyContinue)
if ($haveOpenssl) {
    & openssl req -x509 -newkey rsa:2048 -noenc -keyout $keyPath -out $certPath `
        -days 2 -subj '/CN=os7-check' -addext 'subjectAltName=DNS:os7-check' `
        -addext 'extendedKeyUsage=serverAuth' 2>$null | Out-Null
}

$results = [ordered]@{}

# Everything the fake needs lives INSIDE the OS7 module's scope. Not a closure:
# BUILD-NOTES #96 is what .GetNewClosure() does to a block that has to reach
# $script: state - every recorded call comes back $null.
& (Get-Module OS7) {
    param($lab, $cert, $key, $out, $haveOpenssl)

    $script:OS7RdpStateDir = $lab
    $script:OS7RdpCertPath = $cert
    $script:OS7RdpKeyPath  = $key

    # --- the fake daemon -------------------------------------------------
    $script:__rdState = @{
        enabled = $false; cert = ''; key = ''; user = ''; port = 3389
        present = $true
        # 'deaf' is the M-R25 machine: every call returns 0 and writes nothing.
        deaf = $false
        # 'mute' is grdctl that cannot be asked at all - no stdout.
        mute = $false
    }
    $script:__rdCalls = @()

    $script:OS7RdpCommandOverride = {
        param($cmd, $argv)
        $script:__rdCalls += ($argv -join ' ')
        $s = $script:__rdState

        if (-not $s.deaf) {
            if ($argv -contains 'set-tls-cert')    { $s.cert = $argv[-1] }
            elseif ($argv -contains 'set-tls-key') { $s.key  = $argv[-1] }
            elseif ($argv -contains 'set-credentials') { $s.user = $argv[-2] }
            elseif ($argv -contains 'clear-credentials') { $s.user = '' }
            elseif ($argv -contains 'set-port')    { $s.port = [int]$argv[-1] }
            elseif ($argv -contains 'enable')      { $s.enabled = $true }
            elseif ($argv -contains 'disable')     { $s.enabled = $false }
        }

        if ($argv -contains 'status') {
            if ($s.mute) {
                # grdctl that could not be asked: stderr only, and it STILL
                # exits 0 (M-R25). The TPM line is on stderr on every OS/7
                # machine and is not an error (M-R13/M-R24).
                return [pscustomobject]@{ StdOut = ''; ExitCode = 0
                    StdErr = 'Init TPM credentials failed because No TPM device found, using GKeyFile as fallback.' }
            }
            $showing = $argv -contains '--show-credentials'
            $userLine = if ($s.user) { if ($showing) { $s.user } else { '(hidden)' } } else { '(empty)' }
            $pwLine   = if ($s.user) { if ($showing) { 'the-machine-secret' } else { '(hidden)' } } else { '(empty)' }
            $text = @(
                'Overall:'
                "`tUnit status: " + $(if ($s.enabled) { 'active' } else { 'inactive' })
                'RDP:'
                "`tStatus: " + $(if ($s.enabled) { 'enabled' } else { 'disabled' })
                "`tPort: $($s.port)"
                "`tAuthentication methods: credentials"
                "`tTLS certificate: " + $(if ($s.cert) { $s.cert } else { '(null)' })
                "`tTLS fingerprint: " + $(if ($s.cert) { 'de:ad:be:ef' } else { '(null)' })
                "`tTLS key: " + $(if ($s.key) { $s.key } else { '(null)' })
                "`tKerberos keytab: (null)"
                "`tUsername: $userLine"
                "`tPassword: $pwLine"
            ) -join "`n"
            return [pscustomobject]@{ StdOut = $text; ExitCode = 0
                StdErr = 'Init TPM credentials failed because No TPM device found, using GKeyFile as fallback.' }
        }
        return [pscustomobject]@{ StdOut = ''; ExitCode = 0; StdErr = '' }
    }

    $r = [ordered]@{}

    function Reset-Fake {
        param([switch]$Deaf, [switch]$Mute, [switch]$Enabled, [switch]$WithCert, [switch]$WithUser)
        $script:__rdCalls = @()
        $script:__rdState = @{
            enabled = [bool]$Enabled
            cert = $(if ($WithCert) { $script:OS7RdpCertPath } else { '' })
            key  = $(if ($WithCert) { $script:OS7RdpKeyPath } else { '' })
            user = $(if ($WithUser) { 'os7-rdp' } else { '' })
            port = 3389; present = $true
            deaf = [bool]$Deaf; mute = [bool]$Mute
        }
    }

    # --- 1. a machine with no daemon --------------------------------------
    # Test-OS7RdpSupported short-circuits TRUE whenever the override is set, so
    # the unsupported machine is made by taking the override away.
    $keep = $script:OS7RdpCommandOverride
    $script:OS7RdpCommandOverride = $null
    $script:OS7RdpCtl = Join-Path $lab 'no-such-grdctl'
    $unsupported = Get-OS7RemoteDesktop
    $r.unsupported_supported = $unsupported.Supported
    $r.unsupported_enabled_is_null = ($null -eq $unsupported.Enabled)
    $r.unsupported_detail = $unsupported.Detail
    $enableThrew = $false; $enableMsg = ''
    try { Enable-OS7RemoteDesktop -AllowAnySource -Confirm:$false | Out-Null }
    catch { $enableThrew = $true; $enableMsg = $_.Exception.Message }
    $r.unsupported_enable_threw = $enableThrew
    $r.unsupported_enable_message = $enableMsg
    $script:OS7RdpCommandOverride = $keep

    # --- 2. Enable refuses without a source scope --------------------------
    Reset-Fake -WithCert
    $scopeThrew = $false; $scopeMsg = ''
    try { Enable-OS7RemoteDesktop -Confirm:$false | Out-Null }
    catch { $scopeThrew = $true; $scopeMsg = $_.Exception.Message }
    $r.noscope_threw = $scopeThrew
    $r.noscope_message = $scopeMsg
    # And it must have written NOTHING before refusing.
    $r.noscope_calls = @($script:__rdCalls)

    # --- 3. the order, and that enable is LAST -----------------------------
    Reset-Fake
    if ($haveOpenssl) {
        $enabled = Enable-OS7RemoteDesktop -AllowAnySource -Confirm:$false
        $r.order_calls = @($script:__rdCalls)
        $r.order_enabled = $enabled.Enabled
        $r.order_credential_set = $enabled.CredentialSet
        $r.order_cert_present = $enabled.CertificatePresent
    }
    else { $r.order_calls = @('NO-OPENSSL') }

    # --- 4. the credential never reaches a stream --------------------------
    # Every stream of the enable, plus the object it returns as JSON.
    Reset-Fake
    if ($haveOpenssl) {
        $streams = & {
            Enable-OS7RemoteDesktop -AllowAnySource -Confirm:$false |
                ConvertTo-Json -Depth 5
        } *>&1 | Out-String
        $r.enable_streams = $streams
        # The secret the fake would reveal if anything asked for it.
        $r.enable_streams_has_secret = $streams.Contains('the-machine-secret')
    }

    # --- 5. a deaf grdctl must be caught, not believed ---------------------
    Reset-Fake -Deaf
    $deafThrew = $false; $deafMsg = ''
    try { Enable-OS7RemoteDesktop -AllowAnySource -Confirm:$false | Out-Null }
    catch { $deafThrew = $true; $deafMsg = $_.Exception.Message }
    $r.deaf_threw = $deafThrew
    $r.deaf_message = $deafMsg

    # --- 6. grdctl that cannot be asked: $null, never $false ---------------
    Reset-Fake -Mute
    $mute = Get-OS7RemoteDesktop
    $r.mute_enabled_is_null = ($null -eq $mute.Enabled)
    $r.mute_credential_is_null = ($null -eq $mute.CredentialSet)
    $r.mute_cert_is_null = ($null -eq $mute.CertificatePresent)
    $r.mute_reason = $mute.StatusReason
    $r.mute_supported = $mute.Supported

    # --- 7. P6: enabled, with a certificate, and no credential -------------
    Reset-Fake -Enabled -WithCert
    $noCred = Get-OS7RemoteDesktop
    $r.nocred_enabled = $noCred.Enabled
    $r.nocred_credential_set = $noCred.CredentialSet
    $r.nocred_detail = $noCred.Detail

    # ... and enabled with no certificate at all
    Reset-Fake -Enabled
    $noCert = Get-OS7RemoteDesktop
    $r.nocert_enabled = $noCert.Enabled
    $r.nocert_cert_present = $noCert.CertificatePresent
    $r.nocert_detail = $noCert.Detail

    # --- 8. Disable clears the credential unless told not to ---------------
    Reset-Fake -Enabled -WithCert -WithUser
    $off = Disable-OS7RemoteDesktop -Confirm:$false
    $r.disable_calls = @($script:__rdCalls)
    $r.disable_enabled = $off.Enabled
    $r.disable_credential_set = $off.CredentialSet

    Reset-Fake -Enabled -WithCert -WithUser
    $offKeep = Disable-OS7RemoteDesktop -KeepCredential -Confirm:$false
    $r.disablekeep_calls = @($script:__rdCalls)
    $r.disablekeep_credential_set = $offKeep.CredentialSet

    # --- 9. Set-OS7RemoteDesktopCertificate validates BEFORE writing -------
    Reset-Fake
    $junk = Join-Path $lab 'not-a-certificate.pem'
    Set-Content -LiteralPath $junk -Value 'this is not a certificate'
    $badThrew = $false
    try { Set-OS7RemoteDesktopCertificate -CertPath $junk -KeyPath $junk -InPlace -Confirm:$false | Out-Null }
    catch { $badThrew = $true }
    $r.badcert_threw = $badThrew
    $r.badcert_calls = @($script:__rdCalls)

    # --- 10. -Reveal is the only path that asks for the plaintext ----------
    Reset-Fake -Enabled -WithCert -WithUser
    $cred = Set-OS7RemoteDesktopCredential -Reveal -Confirm:$false
    $r.reveal_is_credential = ($cred -is [pscredential])
    $r.reveal_username = $cred.UserName
    $r.reveal_used_show = @($script:__rdCalls | Where-Object { $_ -like '*--show-credentials*' }).Count
    # Nothing else may use --show-credentials.
    Reset-Fake -Enabled -WithCert -WithUser
    Get-OS7RemoteDesktop | Out-Null
    $r.get_used_show = @($script:__rdCalls | Where-Object { $_ -like '*--show-credentials*' }).Count

    # --- 11. a generated password is not trivially guessable ---------------
    $pw1 = New-OS7RemoteDesktopPassword
    $pw2 = New-OS7RemoteDesktopPassword
    $p1 = ConvertFrom-OS7RdpSecureString -Secure $pw1
    $p2 = ConvertFrom-OS7RdpSecureString -Secure $pw2
    $r.password_length = $p1.Length
    $r.password_differs = ($p1 -ne $p2)
    # -cnotmatch, not -notmatch: PowerShell's operators are case-INSENSITIVE
    # by default, so the lower-case form of this class would reject the very
    # letters the alphabet deliberately keeps.
    $r.password_alphabet_safe = ($p1 -cnotmatch '[0O1lI]')

    # --- 12. the Unix mode of a generated key ------------------------------
    if ($IsLinux -and $haveOpenssl) {
        Reset-Fake
        # A CONTAINER-LOCAL directory, never the bind-mounted lab: on Docker
        # Desktop a Windows bind mount presents every path as 0777 and does not
        # take a mode at all (BUILD-NOTES #117), so generating there would test
        # the mount rather than the cmdlet.
        $native = Join-Path ([System.IO.Path]::GetTempPath()) ('os7rd-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $native
        $script:OS7RdpStateDir = $native
        $script:OS7RdpCertPath = Join-Path $native 'tls.crt'
        $script:OS7RdpKeyPath  = Join-Path $native 'tls.key'
        # chown to the daemon's account fails where that user does not exist;
        # the MODE is what this asserts, so the failure is recorded, not fatal.
        try { New-OS7RemoteDesktopCertificate -Confirm:$false | Out-Null }
        catch { $r.key_generation_error = $_.Exception.Message }
        if (Test-Path -LiteralPath $script:OS7RdpKeyPath) {
            $mode = [System.IO.File]::GetUnixFileMode($script:OS7RdpKeyPath)
            $r.key_mode = "$mode"
            $r.key_other_readable = ([int]($mode -band [System.IO.UnixFileMode]::OtherRead) -ne 0)
            $r.key_group_writable = ([int]($mode -band [System.IO.UnixFileMode]::GroupWrite) -ne 0)
            $r.key_size = (Get-Item -LiteralPath $script:OS7RdpKeyPath).Length
        }
        $r.unix_mode_checked = $true
    }
    else { $r.unix_mode_checked = $false }

    # --- 13. the sign-in policy, against a PAM directory this test built ----
    $pamdir = Join-Path $lab 'pam.d'
    $null = New-Item -ItemType Directory -Force -Path $pamdir
    $script:OS7RdpPamDirectory = $pamdir
    $script:OS7RdpAccessFile = Join-Path $lab 'rd.access'
    foreach ($svc in @('gdm-authd', 'gdm-password', 'login', 'sshd')) {
        Set-Content -LiteralPath (Join-Path $pamdir $svc) -Value @('#%PAM-1.0', 'auth required pam_unix.so')
    }

    $policyLines = Get-OS7RdpPamPolicyLines
    # NO MODULE LINE MAY CARRY A TRAILING MARKER. PAM has no trailing comments:
    # anything after the arguments IS an argument. Writing `pam_access.so ... #
    # os7-remote-desktop` hands pam_access two options it does not know.
    $moduleLines = @($policyLines | Where-Object { $_ -notmatch '^\s*#' })
    $r.policy_module_lines = $moduleLines.Count
    $r.policy_module_line_has_hash = [bool](@($moduleLines | Where-Object { $_ -match '#' }).Count)
    $r.policy_has_faillock = [bool](@($policyLines | Where-Object { $_ -match 'pam_faillock' }).Count)
    $r.policy_access_is_auth = [bool](@($moduleLines | Where-Object { $_ -match '^auth\s' -and $_ -match 'pam_access' }).Count)

    $null = Install-OS7RdpPamPolicy
    $state = Test-OS7RdpPamPolicyInstalled
    $r.policy_present = @($state.Present)
    $r.policy_missing = @($state.Missing)
    $r.policy_access_file = (Test-Path -LiteralPath $script:OS7RdpAccessFile)
    $r.policy_access_rule = @(Get-Content -LiteralPath $script:OS7RdpAccessFile |
        Where-Object { $_ -notmatch '^\s*#' }) -join ''
    # The console and ssh must NEVER receive it.
    $r.policy_touched_login = (Select-String -Path (Join-Path $pamdir 'login') -Pattern 'pam_access' -Quiet) -eq $true
    $r.policy_touched_sshd = (Select-String -Path (Join-Path $pamdir 'sshd') -Pattern 'pam_access' -Quiet) -eq $true

    # Idempotent: installing twice must not double the block.
    $null = Install-OS7RdpPamPolicy
    # MODULE lines only. One of the comment lines contains the word pam_access,
    # and counting it made this assertion fail against correct code.
    $r.policy_lines_after_twice = @(Get-Content -LiteralPath (Join-Path $pamdir 'gdm-authd') |
        Where-Object { $_ -match 'pam_access' -and $_ -notmatch '^\s*#' }).Count

    $null = Uninstall-OS7RdpPamPolicy
    $r.policy_after_remove = @(Get-Content -LiteralPath (Join-Path $pamdir 'gdm-authd') |
        Where-Object { $_ -match 'pam_access|os7-remote-desktop' }).Count
    $r.policy_service_intact = @(Get-Content -LiteralPath (Join-Path $pamdir 'gdm-authd')).Count

    # --- 14. the account lockout's decisions --------------------------------
    $lockdir = Join-Path $lab 'pam-configs'
    $null = New-Item -ItemType Directory -Force -Path $lockdir
    $script:OS7LockoutProfileDir = $lockdir
    $script:OS7LockoutConf = Join-Path $lab 'faillock.conf'
    $script:OS7LockoutCommonAuth = Join-Path $lab 'common-auth'

    $pre = Get-OS7LockoutProfileText -Name 'os7-faillock-preauth'
    $af  = Get-OS7LockoutProfileText -Name 'os7-faillock-authfail'
    $r.lock_pre_priority = (($pre | Where-Object { $_ -match '^Priority:' }) -replace '\D', '')
    $r.lock_af_priority  = (($af  | Where-Object { $_ -match '^Priority:' }) -replace '\D', '')
    $r.lock_pre_default_no = [bool](@($pre | Where-Object { $_ -eq 'Default: no' }).Count)
    $r.lock_af_default_no  = [bool](@($af  | Where-Object { $_ -eq 'Default: no' }).Count)
    $r.lock_both_primary = ((@($pre | Where-Object { $_ -eq 'Auth-Type: Primary' }).Count) -eq 1) -and
                           ((@($af  | Where-Object { $_ -eq 'Auth-Type: Primary' }).Count) -eq 1)

    # A stack in the order pam-auth-update produces on the real machine.
    Set-Content -LiteralPath $script:OS7LockoutCommonAuth -Value @(
        'auth	required	pam_faillock.so preauth'
        'auth	[success=4 ignore=ignore default=die]	pam_authd_exec.so /usr/libexec/authd-pam'
        'auth	[success=3 default=ignore]	pam_unix.so nullok try_first_pass'
        'auth	[success=2 default=ignore]	pam_sss.so use_first_pass'
        'auth	[default=die]	pam_faillock.so authfail'
        'auth	requisite	pam_deny.so'
        'auth	required	pam_permit.so')
    $good = Get-OS7LockoutEffective
    $r.lock_order_good = $good.Order

    # The same modules in the WRONG order - what a prepending writer produces.
    Set-Content -LiteralPath $script:OS7LockoutCommonAuth -Value @(
        'auth	required	pam_faillock.so preauth'
        'auth	[default=die]	pam_faillock.so authfail'
        'auth	[success=2 default=ignore]	pam_unix.so nullok try_first_pass'
        'auth	requisite	pam_deny.so')
    $bad = Get-OS7LockoutEffective
    $r.lock_order_bad = $bad.Order
    $r.lock_bad_still_detected = ($bad.Preauth -and $bad.AuthFail)

    # No lockout in the stack at all.
    Set-Content -LiteralPath $script:OS7LockoutCommonAuth -Value @(
        'auth	[success=1 default=ignore]	pam_unix.so'
        'auth	requisite	pam_deny.so')
    $none = Get-OS7LockoutEffective
    $r.lock_absent = ((-not $none.Preauth) -and (-not $none.AuthFail))

    $r | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $out -Encoding utf8
} $Lab $certPath $keyPath (Join-Path $Lab 'result.json') $haveOpenssl

Write-Output 'DRIVER-DONE'
"""


def find_pwsh():
    for name in ("pwsh", "pwsh.exe"):
        p = shutil.which(name)
        if p:
            return p
    return None


def run_native(pwsh):
    lab = tempfile.mkdtemp(prefix="os7-rd-")
    try:
        drv = os.path.join(lab, "driver.ps1")
        with open(drv, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        manifest = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")
        p = subprocess.run(
            [pwsh, "-NoProfile", "-NonInteractive", "-File", drv,
             "-OS7Manifest", manifest, "-Lab", lab],
            capture_output=True, text=True, encoding="utf-8", errors="replace")
        out = os.path.join(lab, "result.json")
        if not os.path.exists(out):
            print(p.stdout[-3000:])
            print(p.stderr[-3000:], file=sys.stderr)
            return None, p.stderr
        with open(out, encoding="utf-8-sig") as f:
            return json.load(f), p.stderr
    finally:
        shutil.rmtree(lab, ignore_errors=True)


def run_container(image):
    """The same driver, on a real Linux filesystem, for the mode assertions."""
    lab = tempfile.mkdtemp(prefix="os7-rd-c-")
    try:
        drv = os.path.join(lab, "driver.ps1")
        with open(drv, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        cmd = [
            "docker", "run", "--rm",
            "-v", f"{REPO}:/work:ro",
            "-v", f"{lab}:/lab",
            "--entrypoint", "", image,
            "/usr/bin/pwsh", "-NoProfile", "-NonInteractive", "-File", "/lab/driver.ps1",
            "-OS7Manifest", "/work/powershell/OS7/OS7.psd1", "-Lab", "/lab",
        ]
        env = dict(os.environ, MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
        p = subprocess.run(cmd, capture_output=True, text=True, env=env,
                           encoding="utf-8", errors="replace")
        out = os.path.join(lab, "result.json")
        if not os.path.exists(out):
            print(p.stdout[-2000:])
            print(p.stderr[-2000:], file=sys.stderr)
            return None, p.stderr
        with open(out, encoding="utf-8-sig") as f:
            return json.load(f), p.stderr
    finally:
        shutil.rmtree(lab, ignore_errors=True)


def assert_logic(r, unix_expected, stderr=""):
    print("\n### a machine with no remote-desktop daemon\n")
    check(r["unsupported_supported"] is False,
          "Supported is $false where gnome-remote-desktop is absent")
    check(r["unsupported_enabled_is_null"],
          "Enabled is $null there, not $false — 'not this product' is not 'off'")
    check("ssh" in (r["unsupported_detail"] or "").lower(),
          "Detail names ssh as the remote path instead of offering a switch that cannot work",
          (r["unsupported_detail"] or "")[:60])
    check(r["unsupported_enable_threw"], "Enable- refuses rather than pretending")

    print("\n### enabling without a source scope (R9)\n")
    check(r["noscope_threw"], "Enable- refuses with neither -AllowFrom nor -AllowAnySource")
    msg = (r["noscope_message"] or "").lower()
    check("allowfrom" in msg and "allowanysource" in msg,
          "the refusal names both ways out", (r["noscope_message"] or "")[:70])
    check("lockout" in msg or "allow-list" in msg or "unthrottled" in msg,
          "the refusal says WHY — no allow-list and no lockout yet (RL4/RL8)")
    check(len(r["noscope_calls"]) == 0,
          "nothing was written to the daemon before the refusal",
          f"{len(r['noscope_calls'])} call(s)")

    print("\n### the order Enable- writes in (M-R28)\n")
    calls = r.get("order_calls") or []
    if calls == ["NO-OPENSSL"]:
        not_checked("Enable-'s call order", "no openssl on this host to make a parseable certificate")
    else:
        joined = [c for c in calls if "status" not in c]
        idx = {}
        for i, c in enumerate(joined):
            for k in ("set-tls-cert", "set-tls-key", "set-credentials", "enable"):
                if k in c and k not in idx:
                    idx[k] = i
        check(all(k in idx for k in ("set-tls-cert", "set-tls-key", "set-credentials", "enable")),
              "all four steps were performed", ", ".join(idx))
        if all(k in idx for k in ("set-tls-cert", "set-tls-key", "set-credentials", "enable")):
            check(idx["set-tls-cert"] < idx["enable"], "the certificate is set BEFORE enable")
            check(idx["set-tls-key"] < idx["enable"], "the key is set BEFORE enable")
            check(idx["set-credentials"] < idx["enable"],
                  "the credential is set BEFORE enable — the daemon reads it at start (M-R28)")
            check(idx["enable"] == max(idx.values()), "enable is LAST")
        check(r.get("order_enabled") is True, "the returned object reports Enabled")
        check(r.get("order_credential_set") is True, "and a credential set")

    print("\n### the machine credential never reaches a stream (P7 / R16)\n")
    if "enable_streams" in r:
        check(r["enable_streams_has_secret"] is False,
              "no stream of Enable- — output, verbose, warning or the JSON of its result — carries the secret")
        check("Reveal" in (r["enable_streams"] or "") or "Reveal" in (stderr or ""),
              "and it says where to get it instead")
    else:
        not_checked("the credential never reaching a stream", "no openssl on this host")

    print("\n### grdctl exits 0 having done nothing (M-R25)\n")
    check(r["deaf_threw"],
          "Enable- throws when the daemon reports nothing was written, rather than believing the exit code")
    check("root" in (r["deaf_message"] or "").lower(),
          "and the message names the cause: it needs root", (r["deaf_message"] or "")[:70])

    print("\n### a question that could not be asked is $null, never $false (P6)\n")
    check(r["mute_supported"] is True, "Supported stays true — grdctl is there, it just did not answer")
    check(r["mute_enabled_is_null"], "Enabled is $null")
    check(r["mute_credential_is_null"], "CredentialSet is $null")
    check(r["mute_cert_is_null"], "CertificatePresent is $null")
    check(bool(r["mute_reason"]), "and StatusReason says why", (r["mute_reason"] or "")[:60])

    print("\n### the two states that look enabled and refuse every client\n")
    check(r["nocred_enabled"] is True and r["nocred_credential_set"] is False,
          "enabled with a certificate and no credential is reported as exactly that")
    check("credential" in (r["nocred_detail"] or "").lower(),
          "and Detail names the missing credential (M-R5)", (r["nocred_detail"] or "")[:70])
    check(r["nocert_enabled"] is True and r["nocert_cert_present"] is False,
          "enabled with no certificate is reported as exactly that")
    check("certificate" in (r["nocert_detail"] or "").lower(),
          "and Detail says the daemon listens on nothing (M-R4)", (r["nocert_detail"] or "")[:70])

    print("\n### Disable-\n")
    dc = " ".join(r["disable_calls"])
    check("disable" in dc, "the backend is disabled")
    check("clear-credentials" in dc,
          "and the machine credential is CLEARED by default — turning RDP off closes the door")
    check(r["disable_credential_set"] is False, "the daemon reports no credential afterwards")
    dk = " ".join(r["disablekeep_calls"])
    check("clear-credentials" not in dk, "-KeepCredential leaves it installed")
    check(r["disablekeep_credential_set"] is True, "and the daemon still reports one")

    print("\n### a certificate is validated by the loader BEFORE the daemon is pointed at it (#111/#64)\n")
    check(r["badcert_threw"], "an unparseable certificate is refused")
    check(len([c for c in r["badcert_calls"] if "set-tls" in c]) == 0,
          "and the daemon was never pointed at it",
          f"{len(r['badcert_calls'])} call(s)")

    print("\n### --show-credentials is used on exactly one path\n")
    check(r["reveal_is_credential"], "-Reveal returns a [pscredential], not a string")
    check(r["reveal_username"] == "os7-rdp",
          "with the fixed machine username", r["reveal_username"])
    check(r["reveal_used_show"] >= 1, "-Reveal is the path that asks for the plaintext")
    check(r["get_used_show"] == 0, "Get-OS7RemoteDesktop never asks for it")

    print("\n### the generated credential\n")
    check(r["password_length"] >= 20, "is long", str(r["password_length"]))
    check(r["password_differs"], "differs between calls")
    check(r["password_alphabet_safe"],
          "and avoids the glyphs an operator would misread out of a console font")

    print("\n### who may sign in: the allow-list (R5)\n")
    check(r.get("policy_module_line_has_hash") is False,
          "no PAM module line carries a trailing marker - PAM has no trailing comments, so one would be an ARGUMENT",
          f"{r.get('policy_module_lines')} module line(s)")
    check(r.get("policy_has_faillock") is False,
          "v1 writes NO pam_faillock line: prepending authfail was measured breaking every login on the service")
    check(r.get("policy_access_is_auth") is True,
          "the rule runs in the AUTH phase - over RDP the account phase is never reached")
    check(sorted(r.get("policy_present") or []) == ["gdm-authd", "gdm-password"],
          "it is installed in both login services", ", ".join(r.get("policy_present") or []))
    check(r.get("policy_access_file") is True, "the access file it names exists")
    rule = (r.get("policy_access_rule") or "")
    check("ALL EXCEPT LOCAL" in rule,
          "the origin half exempts LOCAL, which is what a console login is", rule[:60])
    check("os7-remotedesktop" in rule and "sudo" in rule,
          "the user half is the allow-list group and the administrators")
    check(r.get("policy_touched_login") is False and r.get("policy_touched_sshd") is False,
          "THE CONSOLE AND SSH ARE UNTOUCHED - the safe-failure property")
    check(r.get("policy_lines_after_twice") == 1,
          "installing twice leaves ONE rule, not two", str(r.get("policy_lines_after_twice")))
    check(r.get("policy_after_remove") == 0,
          "removing it takes every line back out")
    check(r.get("policy_service_intact", 0) >= 2,
          "and leaves the service's own stack behind", f"{r.get('policy_service_intact')} lines")

    print("\n### the account lockout: order is the whole property (R10, #125)\n")
    check(r.get("lock_pre_priority") == "1100",
          "the check runs before every authenticator", "priority " + str(r.get("lock_pre_priority")))
    check(r.get("lock_af_priority") == "64",
          "the record runs after them", "priority " + str(r.get("lock_af_priority")))
    check(r.get("lock_both_primary") is True,
          "both are Auth-Type: Primary - an Additional block lands after pam_deny, where a deny decides nothing")
    check(r.get("lock_pre_default_no") is True and r.get("lock_af_default_no") is True,
          "both are Default: no - no update may switch a lockout on by itself")
    check(r.get("lock_order_good") is True,
          "the order pam-auth-update produces is recognised as correct")
    check(r.get("lock_order_bad") is False,
          "the PREPENDED order - the one that broke every login on a service - is recognised as WRONG")
    check(r.get("lock_bad_still_detected") is True,
          "and it is still reported as present, so the machine says 'wrong' rather than 'absent'")
    check(r.get("lock_absent") is True,
          "a stack with no lockout reads as no lockout")

    print("\n### the private key's mode at generation (P7, BUILD-NOTES #117)\n")
    if r.get("unix_mode_checked"):
        if "key_mode" in r:
            check(r["key_other_readable"] is False,
                  "the key is never other-readable", r.get("key_mode", ""))
            check(r["key_group_writable"] is False,
                  "and never group-writable", r.get("key_mode", ""))
        else:
            check(False, "a key was generated to inspect",
                  (r.get("key_generation_error") or "no error was recorded")[:120])
    elif unix_expected:
        check(False, "the Unix-mode half ran")
    else:
        not_checked("the private key's mode at generation",
                    "needs a Linux filesystem: run with --container os7img:<tag>")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--container", metavar="IMAGE",
                    help="also run the driver on a real Linux filesystem in this image")
    a = ap.parse_args()

    pwsh = find_pwsh()
    if not pwsh:
        print("      NOTE  NOT CHECKED. pwsh is needed and is not on PATH.")
        return 0

    print(f"### the Remote Desktop decisions, against a fake daemon\n")
    print(f"      pwsh: {pwsh}")
    r, stderr = run_native(pwsh)
    if r is None:
        print("      FAIL  the driver produced no result")
        return 1
    assert_logic(r, unix_expected=(platform.system() == "Linux"), stderr=stderr)

    if a.container:
        print(f"\n\n### the same decisions on a real Linux filesystem ({a.container})\n")
        rc, cstderr = run_container(a.container)
        if rc is None:
            print("      FAIL  the container driver produced no result")
            FAILS.append("container run")
        else:
            assert_logic(rc, unix_expected=True, stderr=cstderr)

    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED:")
        for f in FAILS:
            print(f"  - {f}")
        return 1
    tail = f"; {len(NOTCHECKED)} not checked here" if NOTCHECKED else ""
    print(f"All Remote Desktop decision checks passed{tail}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
