#!/usr/bin/env python3
"""
`Get-OS7SecureBoot`'s decisions, against a filesystem that is not a machine.

    ./installer/testing/check-secureboot-logic.py      seconds, no VM, both hosts

WHAT IT IS FOR. The cmdlet answers three questions with three outcomes each,
and the outcomes are the point: "this is not a UEFI machine", "this firmware
has no Secure Boot support" and "supported, but switched off" send an operator
to three different places, and a cmdlet that collapsed them into a boolean
would send them to the wrong one. None of that needs a machine — the answers
come out of two paths under /sys — so it is asked here of fake roots instead
of a VM, and asked of the SHIPPED module.

TWO RULES CARRY REAL DEFECTS AND ARE PLANTED HERE ON PURPOSE:

  * AN EFIVARFS FILE IS FOUR BYTES OF ATTRIBUTES AND THEN THE DATA. Reading
    byte 0 returns the low byte of the attribute word, which is never zero for
    a variable that exists — so it is truthy for every variable in the store,
    including a SecureBoot of 0. The fixture writes the attribute word a real
    machine writes, `06 00 00 00` (BOOTSERVICE_ACCESS|RUNTIME_ACCESS, measured
    2026-09-08 — SecureBoot is volatile, so NON_VOLATILE is not set), and a
    second case writes `07` because an implementation reading byte 0 must fail
    on both. Either way it passes every other case in this file and fails
    these two.

  * /sys/kernel/security/lockdown LISTS every mode and BRACKETS the live one:
    `none [integrity] confidentiality`. The first word is 'none' on a
    locked-down machine, so an implementation that split on whitespace and
    took [0] would report a machine with no lockdown as having none — the
    answer an operator wants least, in the case where it matters most.

Neither is hypothetical: both were written from the byte layout, and this file
is what says the code follows it rather than the comment.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
# OS7_SB_MODULE redirects this at another copy of the module, which is how the
# two planted rules are proven to FIRE rather than only to stay quiet: copy
# powershell/OS7 aside, break the byte offset or the bracket parse in the
# copy, point this at it, and require RED. check-ps-traps.py's OS7_SCAN_ROOT
# exists for the same reason and this is the same argument — a rule that has
# only ever been green is a rule nobody has seen work.
MODULE = os.environ.get("OS7_SB_MODULE") or os.path.join(
    REPO, "powershell", "OS7", "OS7.psd1")

_ok = 0
_bad = 0


def check(cond, what, detail=""):
    global _ok, _bad
    if cond:
        _ok += 1
        print(f"  ok    {what}" + (f" — {detail}" if detail else ""))
    else:
        _bad += 1
        print(f"  FAIL  {what}" + (f" — {detail}" if detail else ""))
    return bool(cond)


GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"


def fake_root(base, name, *, efi=True, efivars=True,
              secureboot=None, setupmode=None, lockdown=None,
              secureboot_bytes=None):
    """One machine's worth of /sys, as files.

    `secureboot`/`setupmode` are written the way efivarfs presents them: four
    attribute bytes followed by the one data byte. The attribute word is
    `06 00 00 00` because that is what a machine wrote — measured 2026-09-08,
    BOOTSERVICE_ACCESS|RUNTIME_ACCESS, with NON_VOLATILE clear because
    SecureBoot is volatile and firmware-owned. It was `07` here until then,
    taken from the convention instead of from a machine.

    `secureboot_bytes` writes something else entirely, for the cases that are
    about the LAYOUT rather than the value.
    """
    root = os.path.join(base, name)
    if efi:
        efidir = os.path.join(root, "sys", "firmware", "efi")
        os.makedirs(efidir, exist_ok=True)
        if efivars:
            vardir = os.path.join(efidir, "efivars")
            os.makedirs(vardir, exist_ok=True)
            for var, val in (("SecureBoot", secureboot), ("SetupMode", setupmode)):
                if val is None:
                    continue
                with open(os.path.join(vardir, f"{var}-{GUID}"), "wb") as fh:
                    fh.write(bytes([0x06, 0, 0, 0, 1 if val else 0]))
            if secureboot_bytes is not None:
                with open(os.path.join(vardir, f"SecureBoot-{GUID}"), "wb") as fh:
                    fh.write(bytes(secureboot_bytes))
    if lockdown is not None:
        sec = os.path.join(root, "sys", "kernel", "security")
        os.makedirs(sec, exist_ok=True)
        with open(os.path.join(sec, "lockdown"), "w") as fh:
            fh.write(lockdown + "\n")
    return root


# The cases, and what each of them is FOR. Order is the report's order.
CASES = [
    ("no-efi", dict(efi=False),
     "a machine that did not boot UEFI"),
    ("no-efivars", dict(efivars=False),
     "UEFI, but efivarfs is not mounted"),
    ("no-variable", dict(),
     "UEFI with no SecureBoot variable — firmware without the feature"),
    ("off", dict(secureboot=False),
     "supported and switched off"),
    ("on", dict(secureboot=True),
     "supported and enforcing"),
    ("on-setup", dict(secureboot=True, setupmode=True),
     "enforcing, but in key-enrolment mode"),
    ("attrbyte", dict(secureboot_bytes=[0x06, 0, 0, 0, 0]),
     "THE ATTRIBUTE-BYTE TRAP: value 0 behind the REAL attributes, 06"),
    ("attrbyte-on", dict(secureboot_bytes=[0x06, 0, 0, 0, 1]),
     "and the same layout with value 1"),
    ("attrbyte-nv", dict(secureboot_bytes=[0x07, 0, 0, 0, 0]),
     "and a value of 0 behind 07, in case a firmware sets NON_VOLATILE"),
    ("truncated", dict(secureboot_bytes=[0x07, 0, 0, 0]),
     "attributes with no data at all"),
    ("lock-integrity", dict(secureboot=True, lockdown="none [integrity] confidentiality"),
     "THE BRACKET TRAP: the live mode is not the first word"),
    ("lock-none", dict(secureboot=False, lockdown="[none] integrity confidentiality"),
     "and a machine with lockdown off"),
    ("lock-conf", dict(secureboot=True, lockdown="none integrity [confidentiality]"),
     "and the third mode"),
]

PROBE = r"""
$ErrorActionPreference = 'Stop'
Import-Module MODULEPATH -Force
$out = @{}
foreach ($pair in ROOTS.GetEnumerator()) {
    $r = Get-OS7SecureBoot -Root $pair.Value
    $out[$pair.Key] = @{
        Firmware  = $r.Firmware
        Supported = $r.Supported
        Enabled   = $r.Enabled
        SetupMode = $r.SetupMode
        Lockdown  = $r.Lockdown
        Reason    = $r.Reason
        Type      = ($r.PSTypeNames -contains 'OS7.SecureBoot')
    }
}
$out | ConvertTo-Json -Depth 4 -Compress
"""


def run_probe(roots):
    """One pwsh, one module import, every case. Importing the module costs
    more than every check in this file put together."""
    ps_roots = "@{" + "; ".join(
        f"'{k}' = '{v}'".replace("\\", "\\\\") for k, v in roots.items()) + "}"
    script = (PROBE
              .replace("MODULEPATH", "'" + MODULE.replace("\\", "\\\\") + "'")
              .replace("ROOTS", ps_roots))
    out = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", script],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("the module could not be asked:\n" + (out.stderr or out.stdout)[-2000:])
    tail = [ln for ln in out.stdout.splitlines() if ln.strip().startswith("{")]
    if not tail:
        sys.exit("no JSON came back:\n" + out.stdout[-2000:])
    return json.loads(tail[-1])


def main():
    if not shutil.which("pwsh"):
        print("\n### Get-OS7SecureBoot's decisions")
        print("  NOT CHECKED — no pwsh on this host")
        sys.exit(0)

    print("\n### Get-OS7SecureBoot's decisions, against fake roots")
    base = tempfile.mkdtemp(prefix="os7sb-")
    try:
        roots = {name: fake_root(base, name, **kw) for name, kw, _ in CASES}
        got = run_probe(roots)

        for name, _, human in CASES:
            r = got[name]
            print(f"  -- {name}: {human}")
            if name == "no-efi":
                # NOT $false. "This is not a UEFI machine" and "Secure Boot is
                # off" are not the same sentence, and only one of them has a
                # firmware setting behind it.
                check(r["Firmware"] is None and r["Supported"] is None
                      and r["Enabled"] is None,
                      "Firmware, Supported and Enabled are all null",
                      f"{r['Firmware']!r}/{r['Supported']!r}/{r['Enabled']!r}")
                check(bool(r["Reason"]) and "sys/firmware/efi" in
                      r["Reason"].replace("\\", "/"),
                      "and the reason names the path it looked for",
                      (r["Reason"] or "")[:70])
            elif name == "no-efivars":
                check(r["Firmware"] == "UEFI", "the firmware is UEFI", r["Firmware"])
                check(r["Supported"] is None and r["Enabled"] is None,
                      "but nothing could be asked", f"{r['Supported']!r}")
                check("efivarfs" in (r["Reason"] or ""),
                      "and the reason says efivarfs", (r["Reason"] or "")[:70])
            elif name == "no-variable":
                # FALSE, NOT NULL. The firmware WAS asked and answered by not
                # having the variable — which is a fact about the firmware, and
                # the one mokutil renders as "doesn't support Secure Boot".
                check(r["Supported"] is False,
                      "Supported is FALSE: the firmware has no Secure Boot",
                      repr(r["Supported"]))
                check(r["Enabled"] is None,
                      "and Enabled stays null, because there was nothing to read",
                      repr(r["Enabled"]))
                check("no Secure Boot support" in (r["Reason"] or ""),
                      "and the reason says so", (r["Reason"] or "")[:70])
            elif name == "off":
                check(r["Supported"] is True and r["Enabled"] is False,
                      "supported, not enforcing",
                      f"{r['Supported']!r}/{r['Enabled']!r}")
            elif name == "on":
                check(r["Supported"] is True and r["Enabled"] is True,
                      "supported and enforcing",
                      f"{r['Supported']!r}/{r['Enabled']!r}")
                check(r["Type"], "and the object carries its type name")
            elif name == "on-setup":
                check(r["Enabled"] is True and r["SetupMode"] is True,
                      "SetupMode is reported beside Enabled",
                      f"{r['Enabled']!r}/{r['SetupMode']!r}")
            elif name == "attrbyte":
                # THE ONE THAT CATCHES A REAL IMPLEMENTATION MISTAKE.
                check(r["Enabled"] is False,
                      "the DATA byte decides, not the attribute byte",
                      f"Enabled={r['Enabled']!r} (byte 0 is 0x06 and truthy)")
            elif name == "attrbyte-nv":
                check(r["Enabled"] is False,
                      "still the data byte, whatever the attribute word is",
                      f"Enabled={r['Enabled']!r} (byte 0 is 0x07 and truthy)")
            elif name == "attrbyte-on":
                check(r["Enabled"] is True,
                      "and the same layout reads true when the data byte is 1",
                      repr(r["Enabled"]))
            elif name == "truncated":
                check(r["Supported"] is False and r["Enabled"] is None,
                      "a variable with no data is no variable",
                      f"{r['Supported']!r}/{r['Enabled']!r}")
            elif name == "lock-integrity":
                check(r["Lockdown"] == "integrity",
                      "the BRACKETED mode is the answer, not the first word",
                      repr(r["Lockdown"]))
            elif name == "lock-none":
                check(r["Lockdown"] == "none",
                      "and 'none' is reported when 'none' is the live one",
                      repr(r["Lockdown"]))
            elif name == "lock-conf":
                check(r["Lockdown"] == "confidentiality",
                      "and the third mode reads back too", repr(r["Lockdown"]))

        # Lockdown is absent from every root that did not ask for it, and that
        # must be null rather than 'none' — a machine whose kernel has no
        # lockdown support at all has not told us it is unprotected.
        check(got["on"]["Lockdown"] is None,
              "a machine with no lockdown file reports null, not 'none'",
              repr(got["on"]["Lockdown"]))
    finally:
        shutil.rmtree(base, ignore_errors=True)

    print(f"\n  {_ok} ok, {_bad} failed")
    print("check-secureboot-logic:", "GREEN" if _bad == 0 else "RED")
    sys.exit(1 if _bad else 0)


if __name__ == "__main__":
    main()
