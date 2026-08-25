#!/bin/bash
# =============================================================================
# Capture REAL ZFS output, to be used as test fixtures.
#
# Runs inside the OS/7 live session, where the ZFS kernel module is actually
# loaded. That qualifier is the whole point of this file: the first attempt to
# answer "which subcommands support -j" was made by chrooting into the shipped
# squashfs, where every zfs invocation fails with "the ZFS modules cannot be
# auto-loaded" BEFORE option parsing — so the probe scored a bogus option and a
# bogus subcommand as supported (docs/ZFS-POWERSHELL-PLAN.md §12, M-Z1).
#
# Nothing here touches a real disk. The pools are built on files in /var/tmp,
# which is the live session's writable overlay.
#
# Every capture is framed by <<<name>>> … <<<end>>> so the host harness can cut
# it out of the serial log. Names match the fixture files under
# powershell/Zfs/tests/fixtures/.
# =============================================================================
set -u

WORK=/var/tmp/zfscap
VDEV_MB=256

say()  { printf '\n<<<%s>>>\n' "$1"; }
end()  { printf '<<<end>>>\n'; }
cap()  { say "$1"; shift; "$@" 2>&1; end; }

echo "ZFS-CAPTURE-START"

# --- a small world with every shape v1 has to read -------------------------
rm -rf "$WORK"; mkdir -p "$WORK"
for f in a b c d; do
	truncate -s "${VDEV_MB}M" "$WORK/$f.img"
done

modprobe zfs 2>/dev/null

# tank: a MIRROR, so zpool status has a nested vdev to nest.
zpool create -f -o ashift=12 -O compression=lz4 tank mirror "$WORK/a.img" "$WORK/b.img"
# vault7: a single-device pool, the trivial shape.
#
# NOT "spare7", which the first capture used and which ZFS refused with "name is
# reserved" — a pool name may not BEGIN with spare, mirror, raidz, draid, log,
# cache, special or dedup. The capture went on to succeed with one pool instead
# of two and nothing in the script noticed.
zpool create -f -o ashift=12 vault7 "$WORK/c.img"

zfs create tank/data
zfs create -o quota=64M -o compression=zstd tank/data/projects
zfs create -V 32M tank/vol                       2>/dev/null   # a zvol
zfs snapshot tank/data@first
zfs snapshot -r tank/data@second
zfs clone tank/data@first tank/restored
zfs set org.os7:role=fixture tank/data           2>/dev/null   # a user property

# ASK ZFS WHETHER THE WORLD IT WAS ASKED FOR EXISTS.
#
# The first run of this script did not, and every `zpool create` return code was
# ignored: `spare7` was refused as a reserved name, the capture carried on, and
# the fixtures came home with one pool where the tests expected two. The failure
# surfaced two steps later as a failing assertion about a parser that was
# correct. This is the repo's standing rule — a program reported success and the
# thing it was meant to change did not change — so the script now asks.
want_pools="tank vault7"
want_ds="tank/data tank/data/projects tank/vol tank/restored"
want_snap="tank/data@first tank/data@second"
missing=
for p in $want_pools; do
	zpool list -H -o name "$p" >/dev/null 2>&1 || missing="$missing pool:$p"
done
for d in $want_ds $want_snap; do
	zfs list -H -o name "$d" >/dev/null 2>&1 || missing="$missing ds:$d"
done
if [ -n "$missing" ]; then
	echo "ZFS-CAPTURE-INCOMPLETE:$missing"
	echo "the fixtures would not cover what the tests assume — refusing to capture"
	exit 1
fi

echo "ZFS-CAPTURE-WORLD-OK"

# --- the read surface, exactly as the module will call it ------------------
cap zpool.list.json      zpool list -j --json-int
cap zpool.status.json    zpool status -j --json-int
cap zpool.get.json       zpool get -j --json-int all tank
cap zfs.list.json        zfs list -j --json-int -t all -r tank
cap zfs.get.json         zfs get -j --json-int all tank/data
cap zfs.get.one.json     zfs get -j --json-int -o all compression,quota,used tank/data/projects

# The same reads WITHOUT --json-int, because the difference decides whether the
# module has to convert strings and how a size arrives.
cap zpool.list.nojsonint zpool list -j
cap zfs.list.nojsonint   zfs list -j -t filesystem -r tank

# --- DEGRADED, which is the state Get-ZpoolStatus exists for ---------------
zpool offline tank "$WORK/b.img"
sleep 1
cap zpool.status.degraded.json  zpool status -j --json-int tank
cap zpool.status.degraded.txt   zpool status tank
zpool online tank "$WORK/b.img" 2>/dev/null

# --- what -j does NOT reach, so the fallback parser has real input ---------
cap zpool.iostat         zpool iostat -Hp tank
cap zpool.history        zpool history tank
cap zfs.holds            zfs holds -H tank/data@first
cap zfs.list.tabbed      zfs list -H -p -o name,used,available,referenced,mountpoint -t all -r tank

# --- error shapes: what a failure actually looks like ----------------------
cap err.nosuch.dataset   zfs list -j nosuchpool/nosuchds
cap err.nosuch.pool      zpool status -j nosuchpool
cap err.destroy.busy     zfs destroy tank/data
say  err.exitcodes
zfs list nosuchpool/x >/dev/null 2>&1; echo "zfs list missing      -> $?"
zpool status nosuchpool >/dev/null 2>&1; echo "zpool status missing -> $?"
zfs list -j nosuchpool/x >/dev/null 2>&1; echo "zfs list -j missing  -> $?"
end

# --- the very large number question (ZFS-POWERSHELL-PLAN §12, not measured) -
say  bignum
zfs set refreservation=none tank/data 2>/dev/null
zfs get -j --json-int -o all available tank 2>&1 | head -c 600
echo
echo "--- is a >2^53 value ever emitted bare? check quota set huge ---"
zfs create -o quota=16E tank/huge 2>&1 | head -2
zfs get -j --json-int -o all quota tank/huge 2>&1 | head -c 400
echo
end

echo "ZFS-CAPTURE-DONE"
