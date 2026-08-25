#!/usr/bin/env python3
"""
Z1: the OS7 module reaches ZFS only through the Zfs module.

    ./check-layering.py            report, and fail if it got worse

docs/ZFS-POWERSHELL-PLAN.md Z1 says Layer 3 (`powershell/OS7`) never invokes
`zfs` or `zpool` itself — every ZFS operation goes through Layer 2
(`powershell/Zfs`). The reason is the one SETUP-PLAN §6.3 already gave for
moving storage out of C#: `Update-OS7` needs snapshot, clone, import, export and
destroy, `New-OS7Storage` needs create, and writing the flags twice guarantees
drift in a dataset hierarchy that cannot be corrected after the fact.

A rule that is only written down erodes. BUILD-NOTES #13, #43 and #45 are three
records of that, so this is the mechanism.

THE BASELINE IS 0 SINCE PHASE Z-4. It was 3 while `New-OS7Storage` still ran
`zpool` and `zfs` itself — the only code path proven to install a machine that
boots, so it was moved last and gated on `run-phase3.py all`. It now goes
through `New-Zpool` and `New-ZfsDataset` like everything else, and the check is
what Z1 actually says rather than a ratchet.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAYER3 = os.path.join(REPO, "powershell", "OS7")

# What a direct invocation looks like in this codebase. Deliberately narrow:
# matching the bare words `zfs`/`zpool` anywhere would hit every comment and
# every doc string, and a check that cries wolf is a check people delete.
#
#   Invoke-OS7Native ... zpool @(...)     the shape OS7.psm1 actually uses
#   & zfs / & zpool                        a direct call operator
#   Start-Process zpool                    the other way to start one
DIRECT = re.compile(
    r"""(?:^|[^\w-])(?:
          Invoke-OS7Native (?:[^\n]*?) \s (zfs|zpool) \s
        | & \s* (zfs|zpool) [\s(]
        | Start-Process \s+ ['"]? (zfs|zpool) \b
        )""",
    re.X,
)

# 0 since phase Z-4. It was 3 before — measured by running this script, not
# counted by eye, which got 24 by counting dataset creations instead of
# invocation sites.
BASELINE = 0


def main() -> None:
    if not os.path.isdir(LAYER3):
        sys.exit(f"no {LAYER3}")

    hits = []
    for root, _, files in os.walk(LAYER3):
        for f in sorted(files):
            if not f.endswith((".psm1", ".ps1", ".psd1")):
                continue
            path = os.path.join(root, f)
            with open(path) as fh:
                for n, line in enumerate(fh, 1):
                    # A line that is only a comment is documentation, not a call.
                    if line.lstrip().startswith("#"):
                        continue
                    if DIRECT.search(line):
                        hits.append((os.path.relpath(path, REPO), n, line.strip()))

    print(f"\n### Z1 — does powershell/OS7 reach ZFS directly?\n")
    for path, n, line in hits:
        print(f"    {path}:{n}  {line[:88]}")

    if not hits:
        print("    (none)")
    print(f"\n    {len(hits)} direct invocation(s); baseline {BASELINE}")

    if len(hits) > BASELINE:
        print(f"\nZ1: FAIL — {len(hits) - BASELINE} more than allowed. OS7 code must "
              f"call the Zfs module, not zfs/zpool (ZFS-POWERSHELL-PLAN Z1).")
        sys.exit(1)
    if len(hits) < BASELINE:
        print(f"\nZ1: IMPROVED — {BASELINE - len(hits)} fewer than the baseline. "
              f"Lower BASELINE in this file to {len(hits)} so it cannot come back.")
        sys.exit(0)
    if BASELINE == 0:
        print("\nZ1: HELD — powershell/OS7 reaches ZFS only through the Zfs module.")
    else:
        print("\nZ1: HELD — unchanged at the baseline.")


if __name__ == "__main__":
    main()
