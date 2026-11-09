#!/usr/bin/env python3
"""
The firstboot migration `81-boot-menu`, run against fakes.

    ./installer/testing/check-boot-menu-migration.py

WHY IT EXISTS. SESSION-QOL-SURVEY Q5 / BRAND-PLAN BRL8 put the boot menu's
wait, colours and memory tests into two files os7-console ships. A fresh
install reads them; a machine that UPDATES did not, because Set-OS7BootEnvironment
generates the new environment's menu in the RUNNING one - the previous release,
which has neither file (measured on bench p272, 1.0.0.272 -> 1.0.0.275,
SESSION-PREVIEW-275). The migration rebuilds the running environment's menu
when it disagrees with that environment's configuration, and only then.

WHAT IT RUNS. The shipped file itself, in a plain ubuntu:26.04 container, with
`update-grub` and `pwsh` replaced by fakes on PATH. The fake update-grub
generates a menu the way grub-mkconfig decides it - it sources /etc/default/grub
and /etc/default/grub.d/*.cfg, runs /etc/grub.d/06_os7_theme when it is
executable, writes the recordfail wait, OS/7's own entry when the machine has
one, and memtest86+'s entries unless they are switched off - so "the menu a
previous environment wrote" is made by running it under the previous
configuration, not typed. The theme script is the one os7-console ships.

WHAT IT DOES NOT. It is not GRUB. Whether the real grub-mkconfig reads these
files is read in the image (SESSION-PREVIEW-275 §4.1), and whether a machine
that updated boots the new menu is the field update's question.

PROVEN TO FIRE. The state question is removed from a COPY of the migration, and
the update case must then do nothing while the menu is stale. A plant whose
text no longer matches is itself a failure. Needs docker; about ten seconds.
"""

import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = "build/packages/os7-release/migrations.d/firstboot/81-boot-menu"
THEME = "build/packages/os7-console/tree/etc/grub.d/06_os7_theme"
DROPIN = "build/packages/os7-console/tree/etc/default/grub.d/50-os7-boot-menu.cfg"
IMAGE = "ubuntu:26.04"

DRIVER = r"""
set -u
mkdir -p /fake/bin /fake/state /boot/grub /etc/default/grub.d /etc/grub.d
cat > /fake/bin/update-grub <<'EOF'
#!/bin/sh
echo call >> /fake/state/grub.log
case "${FAKE_GRUB:-gen}" in fail) exit 1 ;; noop) exit 0 ;; esac
for f in /etc/default/grub /etc/default/grub.d/*.cfg; do [ -f "$f" ] && . "$f"; done
# grub-mkconfig's SECTION MARKERS are part of what is imitated: every script's
# output sits between `### BEGIN /etc/grub.d/<script> ###` and its END, written
# whether the script emits anything or not. Leaving them out is how the first
# version of this check passed a migration that grepped for the word
# `memtest86+` and failed on bench p272 on the marker (SESSION-PREVIEW-275).
sec() { echo "### BEGIN /etc/grub.d/$1 ###"; cat; echo "### END /etc/grub.d/$1 ###"; }
{
  printf 'set menu_color_normal=cyan/blue\nset menu_color_highlight=white/blue\n' | sec 05_debian_theme
  if [ -x /etc/grub.d/06_os7_theme ]; then /etc/grub.d/06_os7_theme | sec 06_os7_theme; fi
  printf 'if [ $grub_platform = efi ]; then\n  set timeout=%s\nfi\nset timeout=%s\n' \
    "${GRUB_RECORDFAIL_TIMEOUT:-30}" "${GRUB_TIMEOUT:-5}" | sec 00_header
  if [ -e /fake/state/os7be ]; then
    echo "menuentry 'OS/7 1.0.0.0 - os7_x' --class os_7 \$menuentry_id_option 'os7-be-os7_x' {"
  fi | sec 09_os7-boot-environments
  if [ "${GRUB_DISABLE_MEMTEST:-}" != true ]; then
    printf '\tmenuentry "Memory test (mt86+x64)" --class memtest $menuentry_id_option "memtest86+" {\n\t}\n'
  fi | sec 20_memtest86+
} > /boot/grub/grub.cfg
EOF
cat > /fake/bin/pwsh <<'EOF'
#!/bin/sh
echo call >> /fake/state/pwsh.log
[ "${FAKE_PWSH:-ok}" = fail ] && exit 1
exit 0
EOF
chmod +x /fake/bin/*
export PATH=/fake/bin:$PATH

previous() {   # the menu the PREVIOUS environment generates: no drop-in, no theme
  rm -f /etc/default/grub.d/* /etc/grub.d/06_os7_theme
  FAKE_GRUB=gen update-grub; rm -f /fake/state/grub.log
}
current() {    # this environment's configuration, as os7-console ships it
  cp /repo/__DROPIN__ /etc/default/grub.d/50-os7-boot-menu.cfg
  cp /repo/__THEME__ /etc/grub.d/06_os7_theme; chmod 0755 /etc/grub.d/06_os7_theme
}

run() {  # name, script, setup...
  name=$1; script=$2; shift 2
  rm -rf /fake/state/* /boot/grub/grub.cfg /etc/default/grub.d/* /etc/grub.d/06_os7_theme
  printf 'GRUB_DEFAULT=saved\nGRUB_TIMEOUT=5\nGRUB_DISTRIBUTOR="OS/7"\n' > /etc/default/grub
  unset FAKE_GRUB FAKE_PWSH
  for s in "$@"; do eval "$s"; done
  out=$(timeout 20 sh "$script" 2>&1); rc=$?
  g=0; [ -e /fake/state/grub.log ] && g=$(wc -l < /fake/state/grub.log)
  p=0; [ -e /fake/state/pwsh.log ] && p=$(wc -l < /fake/state/pwsh.log)
  # ENTRIES, counted the way the migration must count them - the word is in
  # grub-mkconfig's section marker whether there are entries or not.
  w=$(grep -c 'set timeout=30' /boot/grub/grub.cfg 2>/dev/null); m=$(grep -c -- '--class memtest' /boot/grub/grub.cfg 2>/dev/null)
  c=$(sed -n 's/^set menu_color_normal=//p' /boot/grub/grub.cfg 2>/dev/null | tail -1)
  printf '::CASE %s rc=%s grub=%s pwsh=%s wait30=%s memtest=%s colour=%s\n' "$name" "$rc" "$g" "$p" "${w:-x}" "${m:-x}" "${c:-none}"
  printf '%s\n' "$out" | sed 's/^/::OUT /'
}

S=/repo/__SCRIPT__
run no-grub       $S 'rm -f /etc/default/grub'
run current       $S 'current' 'FAKE_GRUB=gen update-grub; rm -f /fake/state/grub.log'
run updated       $S 'touch /fake/state/os7be' 'previous' 'current'
run updated-plain $S 'previous' 'current'
run admin-choices $S 'previous' 'current' \
    'printf "GRUB_RECORDFAIL_TIMEOUT=30\nGRUB_DISABLE_MEMTEST=false\n" > /etc/default/grub.d/90-admin.cfg' \
    'chmod 0644 /etc/grub.d/06_os7_theme'
run grub-noop     $S 'previous' 'current' 'export FAKE_GRUB=noop'
run grub-fails    $S 'previous' 'current' 'export FAKE_GRUB=fail'
run pwsh-fails    $S 'touch /fake/state/os7be' 'previous' 'current' 'export FAKE_PWSH=fail'

# THE PLANT: the state question removed from a copy - it then believes every
# menu is current.
P=/tmp/planted-81
sed 's/^before="$(stale)"$/before=""/' "$S" > "$P"
if cmp -s "$S" "$P"; then echo '::PLANT missed'; else echo '::PLANT made'; fi
run planted-updated $P 'touch /fake/state/os7be' 'previous' 'current'

# THE SECOND PLANT is 1.0.0.276's own defect: the memory-test question asking
# for the WORD, which grub-mkconfig's section marker always contains. On bench
# p272 that rebuilt a correct menu and then failed its read-back at every boot.
P2=/tmp/planted-81-word
sed '/--class memtest/s/grep -Eq.*/grep -q memtest86+ "${CFG}"; then/' "$S" > "$P2"
if cmp -s "$S" "$P2"; then echo '::PLANT2 missed'; else echo '::PLANT2 made'; fi
run planted-word $P2 'touch /fake/state/os7be' 'previous' 'current'
"""


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    driver = (DRIVER.replace("__SCRIPT__", SCRIPT).replace("__THEME__", THEME)
              .replace("__DROPIN__", DROPIN))
    print("\n### 81-boot-menu against fakes (SESSION-PREVIEW-275, Q5 / BRL8)")
    got = subprocess.run(["docker", "run", "--rm", "-v", REPO + ":/repo:ro", IMAGE,
                          "bash", "-c", driver],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    cases, plant, plant2, current = {}, None, None, None
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
        elif line.startswith("::PLANT2 "):
            plant2 = line.split()[1]
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
        c = cases.get(name, {"rc": "?", "grub": "?", "pwsh": "?", "wait30": "?",
                             "memtest": "?", "colour": "?", "out": ""})
        c["last"] = (c["out"].strip().splitlines() or [""])[-1][:110]
        return c

    def fixed(c):
        return c["wait30"] == "0" and c["memtest"] == "0" and c["colour"] == "light-gray/black"

    c = case("no-grub")
    check(c["rc"] == "0" and "nothing to do" in c["out"] and c["grub"] == "0",
          "no GRUB configuration: nothing to do, exit 0", c["last"])
    c = case("current")
    check(c["rc"] == "0" and "nothing to do" in c["out"] and c["grub"] == "0" and c["pwsh"] == "0",
          "a menu this environment generated is left alone — update-grub is never called", c["last"])

    c = case("updated")
    check(c["rc"] == "0" and c["grub"] == "1" and c["pwsh"] == "1",
          "the menu a PREVIOUS environment wrote is rebuilt: update-grub, then "
          "Set-OS7BootEnvironment for OS/7's own entries", "rc=%s grub=%s pwsh=%s" % (c["rc"], c["grub"], c["pwsh"]))
    check("wait" in c["out"] and "memtest" in c["out"] and "colours" in c["out"],
          "and it says which three things were stale", c["out"].splitlines()[0][:110] if c["out"] else "")
    check(fixed(c), "and the menu read back: no 30-second wait, no memory test, light grey on black",
          "wait30=%s memtest=%s colour=%s" % (c["wait30"], c["memtest"], c["colour"]))
    c = case("updated-plain")
    check(c["rc"] == "0" and c["grub"] == "1" and c["pwsh"] == "0" and fixed(c),
          "a machine with no OS/7 entry needs update-grub alone", c["last"])

    c = case("admin-choices")
    check(c["rc"] == "0" and "nothing to do" in c["out"] and c["grub"] == "0",
          "an administrator's 30 s, memory tests and theme switched off: the menu "
          "agrees, nothing is rebuilt", c["last"])

    c = case("grub-noop")
    check(c["rc"] == "1" and "still disagrees" in c["out"],
          "update-grub that exits 0 and changes nothing FAILS the migration — the "
          "result is asked, not the exit code", c["last"])
    c = case("grub-fails")
    check(c["rc"] == "1" and "update-grub failed" in c["out"],
          "a failing update-grub fails the migration", c["last"])
    c = case("pwsh-fails")
    check(c["rc"] == "1" and "Set-OS7BootEnvironment failed" in c["out"],
          "a failing Set-OS7BootEnvironment fails the migration", c["last"])

    check(plant == "made", "the plant found the state question to remove")
    c = case("planted-updated")
    check(c["rc"] == "0" and c["grub"] == "0" and c["wait30"] != "0",
          "PROVEN: without the state question, an updated machine keeps the old menu",
          "rc=%s grub=%s wait30=%s" % (c["rc"], c["grub"], c["wait30"]))

    check(plant2 == "made", "the second plant found the memory-test question to rewrite")
    c = case("planted-word")
    check(c["rc"] == "1" and "still disagrees" in c["out"] and c["memtest"] == "0",
          "PROVEN: asking for the word memtest86+ fails a CORRECT menu on grub-mkconfig's "
          "section marker — 1.0.0.276's defect, red here", "rc=%s memtest=%s — %s" % (c["rc"], c["memtest"], c["last"]))

    print()
    if bad:
        print("%d problem(s)." % bad)
        sys.exit(1)
    print("81-boot-menu rebuilds a menu another environment wrote, leaves a current")
    print("one and an administrator's choices alone, and asks the menu afterwards.")


if __name__ == "__main__":
    main()
