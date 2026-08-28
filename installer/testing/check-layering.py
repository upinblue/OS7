#!/usr/bin/env python3
"""
The layering rules: powershell/OS7 reaches a subsystem only through its module.

    ./check-layering.py            report, and fail if any rule got worse

FIVE RULES SINCE 2026-08-27, and they are the same rule five times. This line
read TWO while the list below held four: P2-time and P2-systemd went in under
it and it was not touched. Count the RULES list, not this sentence.

Z1 (docs/ZFS-POWERSHELL-PLAN.md) says Layer 3 (`powershell/OS7`) never invokes
`zfs` or `zpool` itself — every ZFS operation goes through Layer 2
(`powershell/Zfs`). The reason is the one SETUP-PLAN §6.3 already gave for
moving storage out of C#: `Update-OS7` needs snapshot, clone, import, export and
destroy, `New-OS7Storage` needs create, and writing the flags twice guarantees
drift in a dataset hierarchy that cannot be corrected after the fact.

P2 (docs/POWERSHELL-SURFACE-PLAN.md) says the same about the network:
`powershell/OS7` never invokes `ip`, `netplan`, `nmcli`, `networkctl`,
`resolvectl`, `iw` or `rfkill` — those belong to `powershell/Net`. The argument
is Z1's, with one addition specific to this subsystem: which renderer a machine
takes is a product decision (SETUP-PLAN D14) and where a netplan document is
SPELLED is not, and L24 is the record of what mixing the two costs.

P2'S BASELINE IS 0 AND WAS 0 THE DAY IT WAS WRITTEN. That is deliberate and it
is the cheapest moment to add a rule: `powershell/OS7` had no network code at
all, so the line is drawn before anything can be grandfathered across it. Z1 was
added the other way round — at 3, while `New-OS7Storage` still ran `zpool`
itself — and it took a gated `run-phase3.py all` to get it to 0.

P2-directory (docs/AD-PLAN.md) is the fifth subsystem and the first to start at
1: `getent` was already being asked about a LOCAL account in OS7.Home.ps1
before there was a directory layer to route it through. The site is named in
the rule itself, so the number never has to be explained a second time.

THE HONEST LIMIT OF ALL FIVE: the walk root is `powershell/OS7` and nothing
else. `powershell/Zfs`, `Net`, `Time`, `Systemd` and `Directory` are unpoliced
by construction — nothing here stops the Directory module from shelling
`resolvectl`, and the only defence is that file's own header.

A rule that is only written down erodes. BUILD-NOTES #13, #43 and #45 are three
records of that, so this is the mechanism.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAYER3 = os.path.join(REPO, "powershell", "OS7")


def direct(*commands):
    """What a direct invocation looks like in this codebase.

    Deliberately narrow: matching the bare word `ip` anywhere would hit every
    comment, every doc string and every `$ip` variable, and a check that cries
    wolf is a check people delete.

      Invoke-OS7Native ... zpool @(...)       the shape OS7.psm1 actually uses
      Invoke-OS7Native -Command 'netplan'     the shape the newer cmdlets use
      & zfs / & ip                            a direct call operator
      Start-Process zpool                     the other way to start one

    `(?<![\\w$-])` is what keeps `$ip`, `-ip` and `zip` out of it. It matters
    for the network rule and not for the ZFS one, which is why it arrived with
    the second rule rather than with the first.
    """
    alt = "|".join(commands)
    return re.compile(
        rf"""(?:^|[^\w-])(?:
              Invoke-OS7Native [^\n]*? ['"]? (?<![\w$-]) (?:{alt}) \b ['"]?
            | & \s* ['"]? (?<![\w$-]) (?:{alt}) [\s('"]
            | Start-Process \s+ ['"]? (?<![\w$-]) (?:{alt}) \b
            )""",
        re.X,
    )


class Rule:
    def __init__(self, tag, question, layer2, baseline, commands, verdict):
        self.tag = tag
        self.question = question
        self.layer2 = layer2
        self.baseline = baseline
        self.pattern = direct(*commands)
        self.verdict = verdict


RULES = [
    Rule(
        "Z1", "does powershell/OS7 reach ZFS directly?", "Zfs",
        # 0 since phase Z-4. It was 3 before — measured by running this script,
        # not counted by eye, which got 24 by counting dataset creations instead
        # of invocation sites.
        0,
        ("zfs", "zpool"),
        "powershell/OS7 reaches ZFS only through the Zfs module",
    ),
    Rule(
        "P2", "does powershell/OS7 reach the network directly?", "Net",
        0,
        # `dig`, `host` and `nslookup` joined the tuple on 2026-08-27 with the
        # directory rule below, and they measure 0 — which is the whole reason
        # to add them now rather than later. Finding a domain controller is an
        # SRV lookup, DNS is P2's subsystem and not the directory's, and the
        # line is cheapest to draw before anything has crossed it. That is P2's
        # own argument, made once already by this rule's own baseline.
        #
        # `host` is the loosest token in this file and it was measured before
        # it went in: the Invoke-OS7Native branch runs a lazy [^\n]*? across
        # the whole line, so `Invoke-OS7Native -Command 'ssh' ... # the remote
        # host` and `... @($t.host)` both trip it, while `$Target.Host` and
        # `hostnamectl` do not (the match is case-sensitive and \b-anchored).
        # Both false positives are reachable and neither exists today. No
        # trailing comments on Invoke-OS7Native lines, and spell a property
        # access `.Host`, is the convention that keeps it honest — the same
        # convention `net` was left out of the directory rule to avoid needing.
        ("ip", "netplan", "nmcli", "networkctl", "resolvectl", "iw", "rfkill",
         "wpa_supplicant", "wpa_cli", "dig", "host", "nslookup"),
        "powershell/OS7 reaches the network only through the Net module",
    ),
    Rule(
        "P2-time", "does powershell/OS7 reach the clock directly?", "Time",
        # 0, and it was 1 for about ten minutes: `Sync-OS7Time` called
        # `chronyc makestep` itself before this rule existed to say so. That is
        # the whole argument for writing the rule down as a check rather than as
        # a paragraph — the paragraph was already there, in the file's own
        # header, and the code under it did the other thing.
        0,
        ("chronyc", "chronyd", "timedatectl", "hwclock", "localectl",
         "adjtimex", "ntpdate"),
        "powershell/OS7 reaches the clock only through the Time module",
    ),
    Rule(
        "P2-systemd", "does powershell/OS7 reach systemd directly?", "Systemd",
        # 2, AND THIS ONE STARTED ABOVE ZERO ON PURPOSE. Z1 did too — it began
        # at 3 while New-OS7Storage still ran `zpool` itself — and the rule is
        # the same: a baseline may fall and may not rise. The two that remain
        # are named rather than left to be found:
        #
        #   OS7.Backup.ps1  `systemctl enable --now` for the backup timer
        #   OS7.Update.ps1  `systemctl reboot` at the end of the update train
        #
        # Neither is a unit query and neither is covered by the module's verbs
        # yet. The update train has NEVER RUN ON A MACHINE (docs/HANDOFF.md), so
        # rewriting its reboot to chase a baseline would be changing untested
        # code to satisfy a check rather than to fix a defect.
        2,
        ("systemctl", "journalctl", "systemd-analyze", "loginctl", "busctl",
         "systemd-cat", "systemd-run"),
        "powershell/OS7 reaches systemd only through the Systemd module",
    ),
    Rule(
        "P2-directory", "does powershell/OS7 reach the directory directly?",
        "Directory",
        # 1, and the one is named rather than left to be found:
        #
        #   OS7.Home.ps1:122  `getent passwd <user>` — it predates this rule
        #                     and asks about a LOCAL account, which is the one
        #                     question `getent` answers without a directory
        #                     being involved at all.
        #
        # A baseline may fall and may not rise. `getent` is in the list anyway
        # because once sssd is configured it becomes the canonical "is the join
        # working" probe, and that call belongs to the Directory module.
        #
        # `net` and `ldapsearch`'s siblings are here; `net` alone is NOT, and
        # that is deliberate: the Invoke-OS7Native branch of direct() carries a
        # lazy [^\n]*? across the whole line and only WHOLE-LINE comments are
        # skipped, so the token `net` would fail on any line with the word
        # "net" in a trailing comment. `samba` and `winbind` are absent for the
        # same reason plus a better one: OS/7 does not take that road.
        1,
        ("ldapsearch", "ldapwhoami", "ldapmodify", "ldapadd", "ldapdelete",
         "ldappasswd", "kinit", "klist", "kdestroy", "kvno", "ktutil",
         "adcli", "realm", "sssctl", "sss_cache", "getent"),
        "powershell/OS7 reaches the directory only through the Directory module",
    ),
]


def scan(rule):
    hits = []
    for root, _, files in os.walk(LAYER3):
        for f in sorted(files):
            if not f.endswith((".psm1", ".ps1", ".psd1")):
                continue
            path = os.path.join(root, f)
            with open(path, encoding="utf-8") as fh:
                for n, line in enumerate(fh, 1):
                    # A line that is only a comment is documentation, not a call.
                    if line.lstrip().startswith("#"):
                        continue
                    if rule.pattern.search(line):
                        hits.append((os.path.relpath(path, REPO), n, line.strip()))
    return hits


def report(rule):
    hits = scan(rule)
    print(f"\n### {rule.tag} — {rule.question}\n")
    for path, n, line in hits:
        print(f"    {path}:{n}  {line[:88]}")
    if not hits:
        print("    (none)")
    print(f"\n    {len(hits)} direct invocation(s); baseline {rule.baseline}")

    if len(hits) > rule.baseline:
        print(f"\n{rule.tag}: FAIL — {len(hits) - rule.baseline} more than allowed. "
              f"OS7 code must call the {rule.layer2} module, not these programs.")
        return 1
    if len(hits) < rule.baseline:
        # Not a pass with a note: a baseline that is never lowered is a ratchet
        # that has stopped ratcheting, and the improvement gets reversed by the
        # next commit with nothing to say so.
        print(f"\n{rule.tag}: IMPROVED — {rule.baseline - len(hits)} fewer than the "
              f"baseline. Lower it in this file to {len(hits)} so it cannot come back.")
        return 0
    if rule.baseline == 0:
        print(f"\n{rule.tag}: HELD — {rule.verdict}.")
    else:
        print(f"\n{rule.tag}: HELD — unchanged at the baseline.")
    return 0


def main() -> None:
    if not os.path.isdir(LAYER3):
        sys.exit(f"no {LAYER3}")
    # Every rule runs even after one fails. A run that stops at the first
    # failure reports one problem per fix cycle, which is how a two-rule check
    # becomes a one-rule check in practice.
    failed = sum(report(rule) for rule in RULES)
    print()
    if failed:
        sys.exit(1)
    print(f"{len(RULES)} layering rules held.")


if __name__ == "__main__":
    main()
