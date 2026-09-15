#!/usr/bin/env python3
"""
The automation host's DECISIONS, against a scratch tree. No VM, no ZFS, no root.

    ./installer/testing/check-automation-logic.py            report
    ./installer/testing/check-automation-logic.py --self-test
                                                 plant a defect per rule and
                                                 require every one to FIRE

docs/AUTOMATION-PLAN.md AU14, in the shape `check-layering.py` established: a
named baseline that may fall and may not rise, every violation named on every
run, and every rule proven to fire against a planted defect rather than merely
to stay quiet on a clean tree.

WHY THAT LAST CLAUSE IS NOT CEREMONY. P2-time is this repository's standing
example: the rule was written in capitals in a file header and the code
underneath called `chronyc makestep`. A check that has only ever been green is
indistinguishable from a check that cannot go red, and AUTOMATION-PLAN is a
document in which EVERY decision was Proposed and NOTHING had run — which is
exactly the state in which a rule most needs to be able to fail.

WHAT IT CHECKS, and each one is a decision that would otherwise be a sentence:

  AU1   the boundary, decidable by grep: no cmdlet in this surface contains
        `approval`, `target system`, `role`, `entitlement` or `connector`. The
        plan says the test is a grep; this is the grep.
  AU2   no cmdlet returns a secret VALUE — `Get-OS7Secret`'s output has no
        field that could carry one, and the only [securestring] out of this
        file is Unprotect-'s.
  AU3   the job's input is on stdin and NOWHERE else: not in the drop-in as an
        Environment=, not on the ExecStart line.
  AU4   the PACKAGED template carries every named directive, and the per-run
        drop-in always carries a timeout. `-Unconfined` names what it gives up,
        one directive per line.
  AU5   the intent is written BEFORE the action — proven by making the action
        fail and requiring the intent to be on disk already, which is the same
        evidence killing a job mid-step gives and costs no VM.
  AU6   durable state is outside the boot environment: a dataset under ROOT is
        REFUSED, and so is /var/lib/os7.
  AU8   a lock names its holder, is taken atomically, and reports staleness
        from /proc rather than from the clock.
  AU11  a failing sink is named rather than collapsed into one answer.

IT RUNS ITSELF IN A CONTAINER ON A NON-LINUX HOST, and that is not convenience.
Two of the decisions below are only expressible on Linux and both are load-bearing:

  * `SetUnixFileMode` — the journal is 0640 root:adm and a secret blob is 0600,
    and .NET throws "Unix file modes are not supported on this platform" rather
    than quietly doing nothing. A check that skipped the mode would be a check
    that never looked at the half of AU2 and AU5 an auditor cares about.
  * `/proc/<pid>` — AU8 decides staleness by asking the kernel whether the
    holder still exists. On a host with no /proc every lock reads stale, which
    would turn "a live holder is not stale" into a rule that cannot pass.

It reuses `Dockerfile.check-home` rather than adding a second one: the two
checks want the same thing — Linux, root and the image's own pinned PowerShell —
and a second Dockerfile that drifted from the pin is the failure mode
build/config/os7-release.conf exists to prevent. It does NOT need --privileged
or a private mount namespace; check-home-logic does, for mount(2), and this
does not.

WHAT IT CANNOT SEE: everything that needs a real TPM, a real pool or real
systemd. That is M-AU1 (measured on a machine 2026-09-14, see
docs/SESSION-AUTOMATION-PRIMITIVES.md), M-AU3, M-AU5 and M-AU8, and they are
owed by `docs/AUTOMATION-PLAN.md` §7 rather than by this file.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

MODULE = os.path.join(REPO, "powershell", "OS7", "OS7.Automation.ps1")
PACKAGE = os.path.join(REPO, "build", "packages", "os7-automation", "tree")
TEMPLATE = os.path.join(PACKAGE, "usr", "lib", "systemd", "system", "os7-job@.service")
SLICE = os.path.join(PACKAGE, "usr", "lib", "systemd", "system", "os7-automation.slice")
RUNNER = os.path.join(PACKAGE, "usr", "libexec", "os7-job-run.ps1")

# The container check-home-logic.py builds, reused. Same image, same pin, same
# Dockerfile — see the header.
IMAGE = "os7-check-home"
INSIDE = "OS7_CHECK_AUTOMATION_INSIDE"

# AU1's vocabulary. If one of these words appears in the automation surface,
# the boundary has moved and the operating system has started deciding what a
# product above should decide.
#
# BASELINE 0, AND IT WAS 0 THE DAY IT WAS WRITTEN — the cheapest moment to draw
# a line, the same way P2's network baseline was drawn before powershell/OS7
# had any network code. It may fall (it cannot) and it may not rise.
POLICY_WORDS = ("approval", "approver", "entitlement", "connector",
                "target system", "role assignment")
POLICY_BASELINE = 0

_ok = 0
_bad = 0
_failures = []


def check(cond, what, detail=""):
    global _ok, _bad
    if cond:
        _ok += 1
        print(f"  ok    {what}" + (f" — {detail}" if detail else ""))
    else:
        _bad += 1
        _failures.append(what)
        print(f"  FAIL  {what}" + (f" — {detail}" if detail else ""))
    return bool(cond)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def strip_comments(text):
    """Blank every comment, keeping line numbers.

    check-gui-tokens.py learned this the hard way: its first run went red on a
    BUILD-NOTES reference and on a comment EXPLAINING a colour. Naming a thing
    is not doing it, and a rule that cannot tell the two apart is a rule people
    switch off. Here it matters twice over — this file's own header quotes AU1's
    forbidden vocabulary in order to forbid it.
    """
    out = []
    for line in text.split("\n"):
        s = line.lstrip()
        if s.startswith("#") and not s.startswith("#>"):
            out.append("")
        else:
            # A trailing comment, and the doc-comment blocks <# ... #>, are
            # handled by the block pass below.
            out.append(line)
    text = "\n".join(out)
    # PowerShell block comments, which is where every .SYNOPSIS lives.
    return re.sub(r"<#.*?#>", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)


# ---------------------------------------------------------------------------
# Section 1 — AU1: the boundary, by grep
# ---------------------------------------------------------------------------
def section_boundary(module_text):
    print("\n### AU1 — has the boundary moved?\n")
    body = strip_comments(module_text)
    hits = []
    for n, line in enumerate(body.split("\n"), 1):
        low = line.lower()
        for w in POLICY_WORDS:
            if w in low:
                hits.append((n, w, line.strip()[:70]))
    for n, w, line in hits:
        print(f"    OS7.Automation.ps1:{n}  '{w}'  {line}")
    if not hits:
        print("    (none)")
    print(f"\n    {len(hits)} policy word(s) in the automation surface; "
          f"baseline {POLICY_BASELINE}")
    check(len(hits) <= POLICY_BASELINE,
          "AU1 — the OS provides primitives and a product above provides policy",
          f"{len(hits)} of the forbidden vocabulary, baseline {POLICY_BASELINE}")
    return len(hits)


# ---------------------------------------------------------------------------
# Section 2 — AU4 and AU3: the PACKAGED fence
# ---------------------------------------------------------------------------
# Every one of these is a directive whose ABSENCE is silent. A unit with no
# ProtectSystem= is not an error; it is a job that can write to /usr.
REQUIRED_TEMPLATE = [
    ("Slice=os7-automation.slice", "AU4 — the job is inside the slice"),
    ("ProtectSystem=strict", "AU4 — /usr and /etc are read-only"),
    ("ProtectHome=yes", "AU4 — /home and /root are not visible"),
    ("PrivateTmp=yes", "AU4 — a private /tmp"),
    ("NoNewPrivileges=yes", "AU4 — setuid cannot raise privilege"),
    ("ReadWritePaths=/var/lib/os7-automation", "AU4 — and the job's own state is writable"),
    ("TimeoutStartSec=", "AU4 — a ceiling even for a unit started by hand, in the "
     "directive systemd HONOURS for Type=oneshot (#155)"),
    ("RuntimeDirectory=os7-job/%i", "AU7 — the per-job runtime directory"),
    ("StandardInput=file:/var/lib/os7-automation/jobs/%i/input.json",
     "AU3 — the input is one document on stdin, put there by systemd"),
    ("RemainAfterExit=no", "AU4 — a finished job does not report active forever"),
]


def section_template(template_text, slice_text, runner_text):
    print("\n### AU3 / AU4 — the packaged fence\n")
    for directive, why in REQUIRED_TEMPLATE:
        check(directive in template_text, why, f"os7-job@.service has `{directive}`")

    # AU3's other half, and the one a reviewer would not think to look for: the
    # input must not ALSO arrive by a second road. Two channels for one document
    # is two things to keep in step, and the environment is the one AU3
    # specifically refuses because /proc/<pid>/environ is readable.
    check("Environment=OS7_JOB_INPUT" not in template_text,
          "AU3 — the input does not also arrive in the environment",
          "no Environment=OS7_JOB_INPUT in the template")

    # BUILD-NOTES #155, AND THE REASON THIS RULE IS NEGATIVE. A check that only
    # asked "is there a timeout directive" passed on a unit whose timeout
    # systemd was ignoring: `RuntimeMaxSec=` has no effect with `Type=oneshot`,
    # systemd says so IN THE JOURNAL, loads the unit anyway, and
    # `systemctl show -p RuntimeMaxSec` answers with an empty string. Every job
    # on that machine ran with no bound at all while the fence looked complete.
    #
    # So the rule is that the two must not appear together — the presence of the
    # honoured directive is checked above, and this is the half that would have
    # caught the defect.
    oneshot = "Type=oneshot" in template_text
    check(not (oneshot and re.search(r"(?m)^RuntimeMaxSec=", template_text)),
          "AU4 — the timeout is one systemd honours for this unit's Type (#155)",
          "RuntimeMaxSec= is IGNORED for Type=oneshot, and only the journal says so")

    check("MemoryMax=" in slice_text and "TasksMax=" in slice_text,
          "AU4 — the slice caps all jobs together, not one at a time",
          "os7-automation.slice has MemoryMax and TasksMax")

    # The runner validates its own instance name. `systemctl start
    # os7-job@anything.service` is a command an administrator can type.
    check("ValidatePattern" in runner_text and r"\z" in runner_text,
          "AU10 — the runner does not trust its caller, and anchors with \\z not $",
          "BUILD-NOTES #151: `$` also matches before a trailing newline")


# ---------------------------------------------------------------------------
# Section 3 — the decisions, driven through PowerShell against a scratch tree
# ---------------------------------------------------------------------------
PROBE = r'''
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root    = $env:OS7_AUTOMATION_MODULE_ROOT
$scratch = $env:OS7_AUTOMATION_SCRATCH

Import-Module (Join-Path $root 'Systemd/Systemd.psd1') -Force
Import-Module (Join-Path $root 'OS7/OS7.psd1') -Force

$sm = Get-Module Systemd
$om = Get-Module OS7

# The seams. Everything below runs against a directory tree, with no systemd,
# no ZFS, no TPM and no root.
& $sm {
	param($d)
	$script:SystemdDropInDirectory = $d
	$script:SystemdUnitDirectory   = $d
	# A fake systemctl that answers `show -p LoadState` with `loaded`, so
	# New-SystemdUnitDropIn's assertion can succeed on a machine where there is
	# no systemd at all. Everything else exits 0 and says nothing.
	$script:SystemdCommandOverride = {
		param($cmd, $a)
		$text = ''
		if (($a -join ' ') -match 'LoadState') { $text = 'LoadState=loaded' }
		[pscustomobject]@{ StdOut = $text; StdErr = ''; ExitCode = 0 }
	}
} (Join-Path $scratch 'units')

& $om {
	param($s)
	# The privilege guard reads /proc/self/status, which does not exist on the
	# host this check usually runs on and DOES exist in a container, where it
	# would refuse. Neutralised here on purpose: check-privilege.py is what
	# asserts the guard is present, and this file asserts what the cmdlets
	# DECIDE. One check per question.
	function script:Assert-OS7Elevated { param($Cmdlet, $Because) }
	$script:OS7AutomationRoot = $s
	$script:OS7LockDirectory  = (Join-Path $s 'locks')
} $scratch

foreach ($d in 'secrets', 'journal', 'jobs', 'state', 'locks', 'units') {
	New-Item -ItemType Directory -Force -Path (Join-Path $scratch $d) | Out-Null
}

function Say($tag, $value) { Write-Output ("{0}`t{1}" -f $tag, $value) }

# ---- AU4 / AU3: what the per-run drop-in says ------------------------------
$plain = & $om { param($i, $n) New-OS7JobDropInText -Id $i -Name $n } 'j-0001' 'probe'
Say 'DROPIN_TIMEOUT'          ([bool]($plain -match '(?m)^TimeoutStartSec=\d+'))
Say 'DROPIN_TIMEOUT_HONOURED' ([bool]($plain -notmatch '(?m)^RuntimeMaxSec='))
Say 'DROPIN_NO_INPUT'   ([bool]($plain -notmatch 'OS7_JOB_INPUT'))
Say 'DROPIN_NO_DYNAMIC' ([bool]($plain -notmatch 'DynamicUser'))

$fenced = & $om { param($i, $n) New-OS7JobDropInText -Id $i -Name $n } 'j-0002' 'probe'
Say 'DEFAULT_NOT_UNCONFINED' ([bool]($fenced -notmatch 'ProtectSystem=no'))

$loose = & $om { param($i, $n) New-OS7JobDropInText -Id $i -Name $n -Unconfined } 'j-0003' 'probe'
Say 'UNCONFINED_NAMES_EACH' ([bool](
	$loose -match 'ProtectSystem=no' -and $loose -match 'ProtectHome=no' -and
	$loose -match 'PrivateTmp=no' -and $loose -match 'NoNewPrivileges=no'))

$withSecret = & $om { param($i, $n) New-OS7JobDropInText -Id $i -Name $n -Secret @('svc-a') } 'j-0004' 'probe'
Say 'SECRET_BY_DIRECTIVE' ([bool]($withSecret -match '(?m)^LoadCredentialEncrypted=svc-a:'))
# AU2: the drop-in names the BLOB, never a value, and never an Environment=.
Say 'SECRET_NOT_IN_ENV'  ([bool]($withSecret -notmatch '(?m)^Environment=.*svc-a'))

$withKeytab = & $om { param($i, $n) New-OS7JobDropInText -Id $i -Name $n -Keytab '/etc/krb5.keytab' } 'j-0005' 'probe'
Say 'TICKET_PRIVATE_CACHE' ([bool]($withKeytab -match 'KRB5CCNAME=FILE:%t/os7-job/j-0005/krb5cc'))

# ---- AU8: locks ------------------------------------------------------------
$l = Lock-OS7Resource -Name 'probe-lock' -Confirm:$false
Say 'LOCK_NAMES_HOLDER' ([bool]($l.Holder -and $l.ProcessId -gt 0 -and $l.Since))
Say 'LOCK_NOT_STALE'    ([bool](-not $l.Stale))

$second = $null
try { Lock-OS7Resource -Name 'probe-lock' -Confirm:$false | Out-Null }
catch { $second = $_.Exception.Message }
Say 'LOCK_REFUSES_SECOND' ([bool]($second))
# The refusal must NAME the holder — AU8's whole point is that the question is
# "who has it", not "is it locked".
Say 'LOCK_REFUSAL_NAMES_HOLDER' ([bool]($second -and $second -match [regex]::Escape($l.Holder)))

# A lock whose recorded pid is gone is STALE, and staleness comes from /proc
# rather than from how long it has been held.
$dead = Lock-OS7Resource -Name 'dead-lock' -Holder 'a process that ended' -Confirm:$false
$p = Join-Path (Join-Path $scratch 'locks') 'dead-lock'
$doc = Get-Content -Raw $p | ConvertFrom-Json
$doc.pid = 999999
Set-Content -Path $p -Value ($doc | ConvertTo-Json -Depth 5)
$after = Get-OS7Lock -Name 'dead-lock'
Say 'LOCK_STALE_FROM_PROC' ([bool]($after.Stale))
$broke = $null
try { Lock-OS7Resource -Name 'dead-lock' -Confirm:$false | Out-Null } catch { $broke = $_.Exception.Message }
Say 'LOCK_STALE_NOT_BROKEN' ([bool]($broke))
Say 'LOCK_STALE_SAYS_SO'    ([bool]($broke -and $broke -match 'GONE'))
Lock-OS7Resource -Name 'dead-lock' -Force -Confirm:$false | Out-Null
Say 'LOCK_FORCE_BREAKS' ([bool]((Get-OS7Lock -Name 'dead-lock').ProcessId -eq $PID))

# ---- AU5: the journal ------------------------------------------------------
Write-OS7JobRecord -JobId 'j-9001' -Phase 'Intent' -Record @{ name = 'x' } -Confirm:$false | Out-Null
$recs = Get-OS7JobRecord -JobId 'j-9001'
Say 'JOURNAL_WRITES'   ([bool]($recs.Count -eq 1))
Say 'JOURNAL_SCHEMA'   ([bool]($recs[0].Schema -ge 1))
Say 'JOURNAL_INCOMPLETE' ([bool](-not $recs[0].Complete))
Write-OS7JobRecord -JobId 'j-9001' -Phase 'Result' -Record @{ exitCode = 0 } -Confirm:$false | Out-Null
Say 'JOURNAL_COMPLETE' ([bool]((Get-OS7JobRecord -JobId 'j-9001')[0].Complete))

# A caller cannot overwrite the fixed fields — a record that could say it was
# written at another time is not evidence.
Write-OS7JobRecord -JobId 'j-9002' -Phase 'Intent' -Confirm:$false `
	-Record @{ phase = 'Result'; job = 'somebody-else' } | Out-Null
$forged = @(Get-OS7JobRecord -JobId 'j-9002')
Say 'JOURNAL_FIXED_FIELDS_WIN' ([bool]($forged.Count -eq 1 -and $forged[0].Phase -eq 'Intent'))

# A line that will not parse is REPORTED, not dropped.
$today = Join-Path (Join-Path $scratch 'journal') ([datetime]::UtcNow.ToString('yyyy-MM-dd') + '.jsonl')
Add-Content -Path $today -Value 'this is not json'
Say 'JOURNAL_CORRUPT_REPORTED' ([bool](@(Get-OS7JobRecord | Where-Object Phase -eq 'UNREADABLE').Count -ge 1))

# ---- AU5: THE WRITE-AHEAD PROPERTY -----------------------------------------
# The evidence killing a job mid-step gives, without a VM: make the ACTION fail
# and require the INTENT to be on disk already. If the intent were written
# after the start, this job would leave no trace at all — which is the state a
# product above could not tell from "never asked for".
& $sm {
	$script:SystemdCommandOverride = {
		param($cmd, $a)
		if (($a -join ' ') -match 'LoadState') {
			return [pscustomobject]@{ StdOut = 'LoadState=loaded'; StdErr = ''; ExitCode = 0 }
		}
		if ($a -contains 'start') {
			return [pscustomobject]@{ StdOut = ''; StdErr = 'planted: the machine died here'; ExitCode = 1 }
		}
		[pscustomobject]@{ StdOut = ''; StdErr = ''; ExitCode = 0 }
	}
}
$died = $null
try { Start-OS7Job -Name 'writeahead' -Command 'Get-Date' -Confirm:$false | Out-Null }
catch { $died = $_.Exception.Message }
$ahead = @(Get-OS7JobRecord | Where-Object {
	$_.PSObject.Properties['Record'] -and $_.Record -and
	$_.Record.PSObject.Properties['name'] -and $_.Record.name -eq 'writeahead' })
Say 'WRITEAHEAD_FAILED_AS_PLANNED' ([bool]($died))
Say 'WRITEAHEAD_INTENT_SURVIVES'   ([bool](@($ahead | Where-Object Phase -eq 'Intent').Count -eq 1))
# A unit that could not be started gets a Result, because the runner will never
# write one — an intent with no result is reserved for a machine that died.
Say 'WRITEAHEAD_START_FAILURE_IS_RESULT' ([bool](@($ahead | Where-Object Phase -eq 'Result').Count -eq 1))

# ---- AU6: the refusals -----------------------------------------------------
$underRoot = $null
try { New-OS7ServiceDataset -Name 'probe' -Pool 'rpool/ROOT' -Confirm:$false | Out-Null }
catch { $underRoot = $_.Exception.Message }
Say 'AU6_REFUSES_ROOT' ([bool]($underRoot -and $underRoot -match 'ROOT'))

$underOs7 = $null
try { New-OS7ServiceDataset -Name 'probe' -MountPoint '/var/lib/os7/things' -Confirm:$false | Out-Null }
catch { $underOs7 = $_.Exception.Message }
Say 'AU6_REFUSES_VARLIBOS7' ([bool]($underOs7 -and $underOs7 -match 'boot environment'))

# ---- AU2: the shape that cannot carry a value ------------------------------
$fields = @((Get-Command Get-OS7Secret).ScriptBlock.ToString())
Say 'AU2_GETSECRET_NO_VALUE' ([bool]($fields -notmatch '(?m)^\s*Value\s*=' -and
	$fields -notmatch 'Unprotect-SystemdCredential -Name \$f\.BaseName -Path \$f\.FullName\s*$'))
# @(...) around the call, which is this module's convention throughout and not
# a workaround: a function returning @() unrolls to NOTHING in the pipeline, so
# the caller gets $null and `$x.Count` is a terminating error under
# Set-StrictMode -Version Latest. BUILD-NOTES #112/#119 is the same shape.
$sec = @(Get-OS7Secret)
Say 'AU2_GETSECRET_EMPTY_OK' ([bool]($sec.Count -eq 0))

# ---- AU11: one result per sink --------------------------------------------
Set-OS7NotificationSink -Name 'nowhere' -Type 'command' -Target '/does/not/exist' -Confirm:$false | Out-Null
Set-OS7NotificationSink -Name 'alsonowhere' -Type 'webhook' -Target 'http://127.0.0.1:1/x' -Confirm:$false | Out-Null
$sent = @(Send-OS7Notification -Subject 'probe' -Body 'b' -Confirm:$false)
Say 'AU11_ONE_RESULT_PER_SINK' ([bool]($sent.Count -eq 2))
Say 'AU11_FAILURE_IS_NAMED'    ([bool](@($sent | Where-Object { -not $_.Delivered -and $_.Error }).Count -eq 2))
Say 'AU11_DOES_NOT_THROW'      'True'
'''

# Every probe the PowerShell half emits, with the sentence that says why it
# matters. A probe that is not in this table is not reported, so a probe added
# to the script and forgotten here fails loudly rather than silently passing.
PROBES = [
    ("DROPIN_TIMEOUT", "AU4 — every run carries a timeout systemd honours, so a job that will not end does"),
    ("DROPIN_TIMEOUT_HONOURED", "AU4 — and it is TimeoutStartSec, not the directive systemd ignores (#155)"),
    ("DROPIN_NO_INPUT", "AU3 — the input is not in the drop-in's environment"),
    ("DROPIN_NO_DYNAMIC", "AU4/AUL4 — DynamicUser is not the silent default"),
    ("DEFAULT_NOT_UNCONFINED", "AU4 — the default drop-in does not switch the fence off"),
    ("UNCONFINED_NAMES_EACH", "AU4 — -Unconfined names each directive it gives up, one per line"),
    ("SECRET_BY_DIRECTIVE", "AU2 — a secret reaches a job by LoadCredentialEncrypted=, not by cmdlet"),
    ("SECRET_NOT_IN_ENV", "AU2 — and never through the environment"),
    ("TICKET_PRIVATE_CACHE", "AU7 — a job's ticket cache is its own, under the unit's RuntimeDirectory"),
    ("LOCK_NAMES_HOLDER", "AU8 — a lock says who holds it and since when"),
    ("LOCK_NOT_STALE", "AU8 — a live holder is not stale"),
    ("LOCK_REFUSES_SECOND", "AU8 — a second caller is refused"),
    ("LOCK_REFUSAL_NAMES_HOLDER", "AU8 — and the refusal names the holder, not just the fact"),
    ("LOCK_STALE_FROM_PROC", "AU8 — staleness is asked of /proc, not of the clock"),
    ("LOCK_STALE_NOT_BROKEN", "AU8 — a stale lock is reported, not broken automatically"),
    ("LOCK_STALE_SAYS_SO", "AU8 — and the message says the holder is gone"),
    ("LOCK_FORCE_BREAKS", "AU8 — -Force is how a person decides"),
    ("JOURNAL_WRITES", "AU5 — a record is written and can be read back"),
    ("JOURNAL_SCHEMA", "AU5 — every record carries its schema version (open question 4)"),
    ("JOURNAL_INCOMPLETE", "AU5 — an intent with no result reports Complete = false"),
    ("JOURNAL_COMPLETE", "AU5 — and a result completes it"),
    ("JOURNAL_FIXED_FIELDS_WIN", "AU5 — a caller cannot forge the time, the phase or the job"),
    ("JOURNAL_CORRUPT_REPORTED", "AU5 — an unreadable line is reported, never dropped"),
    ("WRITEAHEAD_FAILED_AS_PLANNED", "AU5 — the planted failure did fail"),
    ("WRITEAHEAD_INTENT_SURVIVES", "AU5 — THE WRITE-AHEAD PROPERTY: the intent was on disk first"),
    ("WRITEAHEAD_START_FAILURE_IS_RESULT",
     "AU5 — a unit that never started gets a Result, so 'interrupted' stays unambiguous"),
    ("AU6_REFUSES_ROOT", "AU6 — a dataset under ROOT is refused, not defaulted away from"),
    ("AU6_REFUSES_VARLIBOS7", "AU6 — and so is /var/lib/os7, the obvious wrong answer"),
    ("AU2_GETSECRET_NO_VALUE", "AU2 — Get-OS7Secret has no field that could carry a value"),
    ("AU2_GETSECRET_EMPTY_OK", "AU2 — an empty store is an empty list, not an error"),
    ("AU11_ONE_RESULT_PER_SINK", "AU11 — one result per sink, never one answer"),
    ("AU11_FAILURE_IS_NAMED", "AU11 — a sink that failed is named, with what it said"),
    ("AU11_DOES_NOT_THROW", "AU11 — a failing sink is not a terminating error: this is usually a catch block"),
]


def run_probe(module_root):
    scratch = tempfile.mkdtemp(prefix="os7-automation-")
    env = dict(os.environ)
    env["OS7_AUTOMATION_MODULE_ROOT"] = module_root
    env["OS7_AUTOMATION_SCRATCH"] = scratch.replace("\\", "/")
    try:
        p = subprocess.run([shutil.which("pwsh") or "pwsh", "-NoProfile", "-Command", PROBE],
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace", env=env, timeout=600)
        out = {}
        for line in (p.stdout or "").split("\n"):
            if "\t" in line:
                k, v = line.split("\t", 1)
                out[k.strip()] = v.strip()
        return out, p
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def section_decisions(module_root):
    print("\n### the decisions, driven against a scratch tree\n")
    probes, p = run_probe(module_root)
    if not probes:
        check(False, "the PowerShell probe ran",
              (p.stderr or p.stdout or "").strip()[:400] or "no output at all")
        return
    for tag, why in PROBES:
        if tag not in probes:
            check(False, why, f"the probe never reported {tag}")
            continue
        check(probes[tag] == "True", why)


# ---------------------------------------------------------------------------
# --self-test: plant a defect per rule and require every one to FIRE
# ---------------------------------------------------------------------------
# The rule this file exists to serve, applied to this file. Each entry is a
# (name, what to break) pair; the run is required to go RED. A rule nothing has
# ever broken is a rule nobody has shown can break.
DEFECTS = [
    ("AU1 — a policy word in the surface",
     "module", lambda t: t.replace(
         "function Get-OS7Lock {",
         "function Get-OS7LockApproval {\n\t# planted\n}\n\nfunction Get-OS7Lock {")),
    ("AU3 — the input channel removed from the template",
     "template", lambda t: t.replace(
         "StandardInput=file:/var/lib/os7-automation/jobs/%i/input.json",
         "# StandardInput removed by --self-test")),
    ("AU4 — ProtectSystem dropped from the template",
     "template", lambda t: t.replace("ProtectSystem=strict", "# ProtectSystem removed")),
    ("AU4 — the slice dropped from the template",
     "template", lambda t: t.replace("Slice=os7-automation.slice", "# Slice removed")),
    ("AU4 — the timeout put back in the directive systemd ignores (#155)",
     "template", lambda t: t.replace("TimeoutStartSec=7200", "RuntimeMaxSec=7200")),
    ("AU5 — the intent written AFTER the action",
     "module", lambda t: t.replace(
         "\tWrite-OS7JobRecord -JobId $id -Phase 'Intent' -Record $intent -Confirm:$false | Out-Null\n",
         "\t# planted: the intent moved below the start\n")),
    ("AU6 — the ROOT refusal removed",
     "module", lambda t: t.replace("if ($dataset -match \"(^|/)ROOT(/|$)\") {",
                                   "if ($false) {")),
    ("AU8 — a lock that does not say who holds it",
     "module", lambda t: t.replace("holder   = $Holder", "holder   = ''")),
    ("AU11 — a failing sink collapsed into one answer",
     "module", lambda t: t.replace("\t$out = foreach ($s in $sinks) {",
                                   "\t$sinks = @($sinks | Select-Object -First 1)\n\t$out = foreach ($s in $sinks) {")),
]


def self_test():
    print("--self-test: each rule against a planted defect. Every one must go RED.\n")
    fired = 0
    for name, where, mutate in DEFECTS:
        tmp = tempfile.mkdtemp(prefix="os7-automation-defect-")
        try:
            # A whole copy of powershell/, because the module imports its
            # neighbours and a half-copy would fail for the wrong reason.
            shutil.copytree(os.path.join(REPO, "powershell"), os.path.join(tmp, "powershell"))
            mod_root = os.path.join(tmp, "powershell")
            mod_path = os.path.join(mod_root, "OS7", "OS7.Automation.ps1")

            tpl = os.path.join(tmp, "os7-job@.service")
            shutil.copyfile(TEMPLATE, tpl)

            if where == "module":
                text = read(mod_path)
                broken = mutate(text)
                if broken == text:
                    print(f"  FAIL  {name} — the planted defect changed nothing; "
                          "the anchor moved and this rule is no longer proven")
                    continue
                with open(mod_path, "w", encoding="utf-8", newline="") as fh:
                    fh.write(broken)
            else:
                text = read(tpl)
                broken = mutate(text)
                if broken == text:
                    print(f"  FAIL  {name} — the planted defect changed nothing")
                    continue
                with open(tpl, "w", encoding="utf-8", newline="") as fh:
                    fh.write(broken)

            global _ok, _bad, _failures
            _ok, _bad, _failures = 0, 0, []
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                section_boundary(read(mod_path))
                section_template(read(tpl), read(SLICE), read(RUNNER))
                if where == "module":
                    section_decisions(mod_root)
            if _bad:
                fired += 1
                print(f"  ok    {name} — CAUGHT ({_bad} check(s) went red)")
            else:
                print(f"  FAIL  {name} — NOT caught. This rule cannot fire.")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n{fired} of {len(DEFECTS)} planted defects were caught.")
    return 0 if fired == len(DEFECTS) else 1


def pin(name):
    """A value out of build/config/os7-release.conf — THE only place in this
    repository a version number may live (CLAUDE.md). The container's PowerShell
    is the image's PowerShell, not a second pin that rots quietly."""
    conf = os.path.join(REPO, "build", "config", "os7-release.conf")
    for line in open(conf, encoding="utf-8"):
        if line.startswith(name + "="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit(f"{name} is not in {conf}")


def relaunch():
    """Build the container and run this file inside it."""
    if not shutil.which("docker"):
        sys.exit("docker is needed on a non-Linux host: this check wants Linux file modes "
                 "and /proc. See the header.")
    print("    building the check container (first run only) \u2026")
    subprocess.run(
        ["docker", "build", "-q", "-t", IMAGE,
         "-f", os.path.join(HERE, "Dockerfile.check-home"),
         "--build-arg", f"PWSH_VERSION={pin('OS7_PWSH_VERSION')}",
         "--build-arg", f"PWSH_SHA256_x64={pin('OS7_PWSH_SHA256_x64')}",
         "--build-arg", f"PWSH_SHA256_arm64={pin('OS7_PWSH_SHA256_arm64')}",
         HERE],
        check=True, stdout=subprocess.DEVNULL)
    # NOT read-only: --self-test copies powershell/ into the container's own
    # /tmp and never writes to the mount, but the copy needs somewhere to go
    # and /repo is not it.
    argv = ["python3", "/repo/installer/testing/check-automation-logic.py"] + sys.argv[1:]
    return subprocess.run(
        ["docker", "run", "--rm", "-e", f"{INSIDE}=1",
         "-v", f"{REPO}:/repo:ro", IMAGE] + argv).returncode


def main():
    # Linux decides two of the rules below (see the header), so on anything
    # else this re-runs itself where they can be decided.
    if not sys.platform.startswith("linux") and not os.environ.get(INSIDE):
        sys.exit(relaunch())

    if "--self-test" in sys.argv:
        sys.exit(self_test())

    if not shutil.which("pwsh"):
        sys.exit("pwsh is not on PATH; this check drives the real cmdlets.")

    print("check-automation-logic — docs/AUTOMATION-PLAN.md phase 1, AU14")
    section_boundary(read(MODULE))
    section_template(read(TEMPLATE), read(SLICE), read(RUNNER))
    section_decisions(os.path.join(REPO, "powershell"))

    print(f"\n  {_ok} ok, {_bad} failed")
    if _bad:
        for f in _failures:
            print(f"    - {f}")
        print("\ncheck-automation-logic: RED")
        sys.exit(1)
    print("\ncheck-automation-logic: GREEN")


if __name__ == "__main__":
    main()
