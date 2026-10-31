#!/usr/bin/env python3
"""
The UL1 firstboot migration `50-tpm2-reseal`, run against fakes.

    ./installer/testing/check-reseal-migration.py

WHY IT EXISTS. BUILD-NOTES #195: when the TPM2 seal no longer opens — a shim
or dbx update, the case UL1 exists for — the migration calls
`systemd-cryptenroll` with no unlock key, and that does not fail. It asks for
the current passphrase through systemd's password agents, with no timeout, and
os7-migrations-firstboot has none either. On a bench the unit sat in
`activating` and every migration after it waited too. The script's header had
promised the opposite ("says so, names the one command an operator runs, and
exits 0"), and the only place that branch had ever run was a container with no
TPM, where the script leaves three lines earlier at "no TPM on this machine".

WHAT IT RUNS. The shipped file itself, in a plain ubuntu:26.04 container, with
`cryptsetup` and `systemd-cryptenroll` replaced by fakes on PATH and the LUKS
device and the TPM replaced by paths (OS7_RESEAL_LUKS, OS7_RESEAL_TPM — which
nothing on a machine sets). The fake enrolment can succeed, refuse, succeed
without the seal opening, or BLOCK the way the real one does while it waits for
a passphrase. Each outcome is read off the script's exit code, its words and
the clock.

WHAT IT DOES NOT. It is not a TPM. Whether systemd-cryptenroll really seals to
PCR 7 is run-s6.py's and run-secureboot.py's question, on a machine.

PROVEN TO FIRE. The bounded ask is removed from a COPY of the script and the
blocking case must then hit the outer limit. A plant whose text no longer
matches is itself a failure, so a rewrite cannot quietly turn this into a check
of nothing. Needs docker; about ten seconds.
"""

import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = "build/packages/os7-release/migrations.d/firstboot/50-tpm2-reseal"
IMAGE = "ubuntu:26.04"
ASK = 3      # seconds the script is given to wait for a passphrase
OUTER = 20   # seconds before a case counts as hanging

# The driver runs every case in one container and prints one marker line per
# case; the checking happens below, in Python, where a failure can say why.
DRIVER = r"""
set -u
mkdir -p /fake/bin /fake/state
cat > /fake/bin/cryptsetup <<'EOF'
#!/bin/sh
# open --test-passphrase --token-only: the seal opens iff the state says so
[ -e /fake/state/sealed ] && exit 0
exit 1
EOF
cat > /fake/bin/systemd-cryptenroll <<'EOF'
#!/bin/sh
echo "$*" >> /fake/state/enroll.log
case "${FAKE_ENROLL:-ok}" in
  block)       exec sleep 1000 ;;                 # waiting for a passphrase
  ok)          touch /fake/state/sealed; exit 0 ;;
  ok-stale)    exit 0 ;;                          # says yes, seals nothing
  refuse)      exit 1 ;;
esac
EOF
chmod +x /fake/bin/*
export PATH=/fake/bin:$PATH OS7_RESEAL_ASK_SECONDS=__ASK__

run() {  # name, script, setup...
  name=$1; script=$2; shift 2
  rm -rf /fake/state/* /fake/luks /fake/tpm0
  for s in "$@"; do eval "$s"; done
  start=$(date +%s)
  out=$(timeout __OUTER__ sh "$script" 2>&1); rc=$?
  secs=$(( $(date +%s) - start ))
  enrolled=no; [ -e /fake/state/enroll.log ] && enrolled=yes
  printf '::CASE %s rc=%s secs=%s enrolled=%s\n' "$name" "$rc" "$secs" "$enrolled"
  printf '%s\n' "$out" | sed 's/^/::OUT /'
}

S=/repo/__SCRIPT__
L='export OS7_RESEAL_LUKS=/fake/luks OS7_RESEAL_TPM=/fake/tpm0'
run no-luks   $S "$L"
run no-tpm    $S "$L" 'touch /fake/luks'
run opens     $S "$L" 'touch /fake/luks; mkdir /fake/tpm0; touch /fake/state/sealed'
run blocks    $S "$L" 'touch /fake/luks; mkdir /fake/tpm0' 'export FAKE_ENROLL=block'
run reseals   $S "$L" 'touch /fake/luks; mkdir /fake/tpm0' 'export FAKE_ENROLL=ok'
run stale     $S "$L" 'touch /fake/luks; mkdir /fake/tpm0' 'export FAKE_ENROLL=ok-stale'
run refused   $S "$L" 'touch /fake/luks; mkdir /fake/tpm0' 'export FAKE_ENROLL=refuse'

# THE PLANT: the bounded ask removed from a copy.
P=/tmp/planted-reseal
sed 's/timeout "${ASK_SECONDS}" systemd-cryptenroll/systemd-cryptenroll/' "$S" > "$P"
if cmp -s "$S" "$P"; then echo '::PLANT missed'; else echo '::PLANT made'; fi
run planted-blocks $P "$L" 'touch /fake/luks; mkdir /fake/tpm0' 'export FAKE_ENROLL=block'
"""


def main():
    # The script's own words carry em dashes; a Windows console's code page
    # must not decide whether they can be printed.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    driver = (DRIVER.replace("__ASK__", str(ASK)).replace("__OUTER__", str(OUTER))
              .replace("__SCRIPT__", SCRIPT))
    print("\n### 50-tpm2-reseal against fakes (BUILD-NOTES #195)")
    got = subprocess.run(["docker", "run", "--rm", "-v", REPO + ":/repo:ro", IMAGE,
                          "bash", "-c", driver],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    cases, plant, current = {}, None, None
    for line in (got.stdout or "").splitlines():
        if line.startswith("::CASE "):
            parts = line.split()
            current = parts[1]
            cases[current] = {"out": ""}
            for kv in parts[2:]:
                k, v = kv.split("=", 1)
                cases[current][k] = v
        elif line.startswith("::OUT ") and current:
            cases[current]["out"] += line[6:] + "\n"
        elif line.startswith("::PLANT "):
            plant = line.split()[1]
    if not cases:
        print(got.stdout[-2000:])
        print(got.stderr[-2000:], file=sys.stderr)
        print("\nThe driver produced no cases at all.")
        sys.exit(1)

    bad = 0

    def check(ok, what, detail=""):
        nonlocal bad
        print("      %s  %s%s" % ("ok  " if ok else "FAIL", what,
                                  (" — " + detail) if detail else ""))
        if not ok:
            bad += 1

    def case(name):
        c = cases.get(name, {"rc": "?", "secs": "?", "enrolled": "?", "out": ""})
        c["last"] = (c["out"].strip().splitlines() or [""])[-1][:110]
        return c

    c = case("no-luks")
    check(c["rc"] == "0" and "not an encrypted" in c["out"],
          "no LUKS device: nothing to re-seal, exit 0", c["last"])
    c = case("no-tpm")
    check(c["rc"] == "0" and "no TPM" in c["out"],
          "no TPM: the passphrase is the unlock path, exit 0", c["last"])
    c = case("opens")
    check(c["rc"] == "0" and "nothing to do" in c["out"] and c["enrolled"] == "no",
          "a seal that opens is left alone — the enrolment is never called", c["last"])

    c = case("blocks")
    secs = int(c["secs"]) if c["secs"].isdigit() else 999
    check(c["rc"] == "0" and secs < OUTER,
          "a passphrase prompt nobody answers ENDS: exit 0 after the bounded ask (#195)",
          "rc=%s after %ss, ask %ss" % (c["rc"], c["secs"], ASK))
    check("nobody typed the passphrase within %ss" % ASK in c["out"],
          "and it says nobody answered", c["last"])
    check("systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7" in c["out"],
          "and names the one command an operator runs")

    c = case("reseals")
    check(c["rc"] == "0" and "re-sealed, and the new seal opens" in c["out"],
          "an answered prompt re-seals, and the seal is asked again", c["last"])
    c = case("stale")
    check(c["rc"] == "1" and "still does not open" in c["out"],
          "an enrolment that says yes and seals nothing FAILS the migration", c["last"])
    c = case("refused")
    check(c["rc"] == "0" and "cannot re-seal unattended" in c["out"]
          and "nobody typed" not in c["out"],
          "a refused enrolment names the command, without claiming a timeout", c["last"])

    check(plant == "made", "the plant found the bounded ask to remove")
    c = case("planted-blocks")
    check(c["rc"] == "124" and c["enrolled"] == "yes",
          "PROVEN: without the bound, the same case hangs until the outer limit",
          "rc=%s after %ss" % (c["rc"], c["secs"]))

    print()
    if bad:
        print("%d problem(s)." % bad)
        sys.exit(1)
    print("50-tpm2-reseal re-seals when someone answers, says what to type when")
    print("nobody does, and never holds the migrations behind an unanswered prompt.")


if __name__ == "__main__":
    main()
