#!/usr/bin/env python3
"""
Firstboot migrations 72 and 73, run against an OS/7 userland in a container.

    ./installer/testing/check-desktop-migrations.py           ~20 s, no VM
    ./installer/testing/check-desktop-migrations.py --image os7img:<tag>

WHAT IT IS FOR. Two migrations repair machines installed before 2026-10-29:

  72-classic-session-default   moves the AccountsService records GDM's fallback
                               wrote (Session=ubuntu, or empty) to gnome-classic,
                               ONCE per machine (BUILD-NOTES #168)
  73-generate-named-locale     generates the locale /etc/default/locale has
                               named since install and nobody generated (#170)

The only gate that runs firstboot migrations on a machine is run-s5.py, and it
installs a HEADLESS machine, where 72 exits at its first line. So the decisions
are asked here, in a container made from an OS/7 image (`os7img:*`, which has
the real locales package, /usr/share/i18n/SUPPORTED and the GNOME session
files), with every scenario's answer read off the filesystem rather than off
the migration's exit code.

#93 applies: a container image made from an ISO is not the ISO. Nothing here
claims anything about a medium; it claims what two shell scripts decide, given
a userland that has the programs they call.

PROVEN TO FIRE. Each migration ends by asking the filesystem whether the thing
it did is true. A copy with the doing removed must therefore FAIL — and the
check requires that it does, because a read-back that has only ever passed is a
read-back nobody has seen work.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MIG = "/repo/build/packages/os7-release/migrations.d/firstboot"

SCENARIOS = r'''
set -u
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; }
want() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — got '$1', want '$2'"; fi; }
M72=__MIG__/72-classic-session-default
M73=__MIG__/73-generate-named-locale
U=/var/lib/AccountsService/users
sess() { sed -n 's/^Session=//p' "$U/$1"; }

echo "### 72-classic-session-default"

# A machine with no desktop session is not touched at all.
mv /usr/share/wayland-sessions/gnome-classic.desktop /tmp/gc.desktop
mkdir -p "$U"; printf '[User]\nSession=ubuntu\n' > "$U/alice"
sh "$M72" >/dev/null; rc=$?
want "$rc" 0 "headless: exits 0"
want "$(sess alice)" ubuntu "headless: a record is left as it is"
want "$(test -e /var/lib/os7/session-default-migrated && echo yes || echo no)" no \
     "headless: no marker, so a later desktop install still gets the migration"
mv /tmp/gc.desktop /usr/share/wayland-sessions/gnome-classic.desktop

# The records GDM's fallback writes, and two it does not.
printf '[User]\nSession=ubuntu\nIcon=/home/alice/.face\n' > "$U/alice"
printf '[User]\nSession=gnome\n'         > "$U/bob"
printf '[User]\nSession=\n'              > "$U/carol"
printf '[User]\nSession=gnome-classic\n' > "$U/dave"
printf '[User]\nSession=ubuntu-xorg\n'   > "$U/erin"
sh "$M72" >/dev/null; rc=$?
want "$rc" 0 "desktop: exits 0"
want "$(sess alice)" gnome-classic "Session=ubuntu is moved"
want "$(grep -c '^Icon=/home/alice/.face$' "$U/alice")" 1 "and the rest of that record is kept"
want "$(sess carol)" gnome-classic "an EMPTY Session= is moved"
want "$(sess bob)" gnome "a session somebody chose (gnome) is left alone"
want "$(sess erin)" ubuntu-xorg "a name that only starts with 'ubuntu' is left alone"
want "$(sess dave)" gnome-classic "gnome-classic stays gnome-classic"
want "$(test -s /var/lib/os7/session-default-migrated && echo yes || echo no)" yes "the marker is written"

# Once per machine: a person who picks Ubuntu afterwards keeps it, across
# every later release's first boot.
printf '[User]\nSession=ubuntu\n' > "$U/alice"
sh "$M72" >/dev/null; rc=$?
want "$rc" 0 "second run: exits 0"
want "$(sess alice)" ubuntu "second run: a later, deliberate Session=ubuntu is NOT undone"

# Planted: the edit removed. The migration's own read-back must catch it.
rm -f /var/lib/os7/session-default-migrated
sed '/sed -Ei .s\/\^Session=/d' "$M72" > /tmp/72-broken
printf '[User]\nSession=ubuntu\n' > "$U/alice"
sh /tmp/72-broken >/dev/null 2>&1; rc=$?
want "$( [ "$rc" -ne 0 ] && echo red || echo green)" red \
     "PLANTED: a copy that never edits FAILS on its own read-back"
want "$(test -e /var/lib/os7/session-default-migrated && echo yes || echo no)" no \
     "PLANTED: and writes no marker, so the next boot tries again"

echo
echo "### 73-generate-named-locale"
printf 'LANG=de_DE.UTF-8\n' > /etc/default/locale
want "$(locale -a | grep -cx de_DE.utf8)" 0 "precondition: de_DE.utf8 does not exist"
sh "$M73" >/dev/null 2>&1; rc=$?
want "$rc" 0 "exits 0"
want "$(locale -a | grep -cx de_DE.utf8)" 1 "glibc lists de_DE.utf8 afterwards"
want "$(grep -cx 'de_DE.UTF-8 UTF-8' /etc/locale.gen)" 1 "and locale.gen carries it, so a locales upgrade keeps it"
out="$(sh "$M73" 2>&1)"; rc=$?
want "$rc" 0 "second run: exits 0"
want "$(echo "$out" | grep -c 'already generated')" 1 "second run: says it had nothing to do"

printf 'LANG="C.UTF-8"\n' > /etc/default/locale
out="$(sh "$M73" 2>&1)"; rc=$?
want "$rc$(echo "$out" | grep -c 'built into glibc')" 01 "C.UTF-8 (quoted): nothing to generate"

printf 'LANG=xx_YY.UTF-8\n' > /etc/default/locale
out="$(sh "$M73" 2>&1)"; rc=$?
want "$rc$(echo "$out" | grep -c 'cannot be generated')" 01 \
     "an unsupported name does not fail the update, and says why"

# Planted: locale-gen removed. glibc's list is the proof, and it must say no.
printf 'LANG=fr_FR.UTF-8\n' > /etc/default/locale
sed 's/^if ! locale-gen; then/if ! true; then/' "$M73" > /tmp/73-broken
sh /tmp/73-broken >/dev/null 2>&1; rc=$?
want "$( [ "$rc" -ne 0 ] && echo red || echo green)" red \
     "PLANTED: a copy that never runs locale-gen FAILS on glibc's list"
'''


def main() -> int:
    image = "os7img:175"
    if "--image" in sys.argv:
        image = sys.argv[sys.argv.index("--image") + 1]
    script = SCENARIOS.replace("__MIG__", MIG)
    # BYTES on stdin: text mode on Windows turns every \n into \r\n and bash
    # then reports a syntax error about a script that is fine (BUILD-NOTES #70,
    # and check-image.py's own comment on the same pipe).
    p = subprocess.run(
        ["docker", "run", "--rm", "-i", "-v", f"{REPO}:/repo:ro", image, "bash", "-s"],
        input=script.encode("utf-8"), capture_output=True)
    out = p.stdout.decode("utf-8", "replace")
    print(f"    {image}, migrations from {MIG.replace('/repo/', '')}\n")
    for line in out.splitlines():
        print(("      " + line) if line.startswith(("ok", "FAIL")) else line)
    ok = sum(1 for l in out.splitlines() if l.startswith("ok"))
    bad = sum(1 for l in out.splitlines() if l.startswith("FAIL"))
    if p.returncode != 0 or (ok + bad) == 0:
        print(p.stderr.decode("utf-8", "replace")[-1500:])
        print("the scenarios did not run to the end")
        return 1
    print(f"\n{ok + bad} checks, {bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
