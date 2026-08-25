# The network screen, and the account model — a premise overturned, then built on

**Date:** 2026-08-25. Against `main` at `c4b3ddb`, "The amd64 Install entry booted
into GNOME, and only a boot could have said so", and the two ISOs built from that
line: `OS7-1.0.0.46-arm64.iso` and `OS7-1.0.0.47-amd64.iso`, both on archive
snapshot `20260824T000000Z`.

The session went in three stages, and the middle one is the reason for the other
two:

1. **It found one sentence in [SETUP-PLAN.md](../installer/SETUP-PLAN.md) that is
   true of Ubuntu and false of this image** — the sentence Phase 3 used to leave
   screen 9 out.
2. **It measured the consequence on a running computer (M1).** An installed
   arm64 machine comes up with its interface DOWN, no address and an empty
   routing table. Not slow, not misconfigured — unreachable, silently.
3. **It then built screen 9**, with the Wi-Fi screens D13 puts in v1 and the
   account-model decision D11 settles.

Stage 2 is what turns this from a tidy-up into the phase's justification, and it
is why it was done before any code was written rather than after.

---

## The finding

Phase 3 delivered screens 7–11 and left screen 9 out, with a reason:

> DHCP is the default on a fresh Ubuntu install and a machine that boots can be
> configured from a shell.

Both shipped images were asked, by mounting the squashfs read-only in the build
container and reading the filesystem rather than reasoning about the
distribution:

| | arm64 (549 pkgs) | amd64 (1528 pkgs) |
|---|---|---|
| `netplan.io` / `netplan-generator` | 1.2 | 1.2 |
| `systemd-resolved`, `networkd-dispatcher` | yes | yes |
| `network-manager` | **no** | 1.54.3 |
| `wpasupplicant` | **no** | 2:2.11 |
| `iw`, `rfkill` | **no** | 6.17, 2.41.3 |
| wireless firmware (Intel, Broadcom, Realtek, MediaTek, Qualcomm, Marvell) | **yes** | yes |
| `/etc/netplan/` | **empty** | **empty** |
| `/etc/systemd/network/` | **empty** | **empty** |
| `cloud-init` | **absent** | **absent** |
| `systemd-networkd` enabled | **no** | no |

**There is nothing on this image that configures a network, except
NetworkManager.** Netplan generates nothing from an empty directory. The only
`.network` files under `/usr/lib/systemd/network/` are for containers, VM tunnels,
6rd and `.example` templates — none of them matches a physical NIC. And
`systemd-networkd` is not enabled.

What *is* enabled, in `/etc/systemd/system/multi-user.target.wants/`, is
`networkd-dispatcher.service` — which exists to react to `systemd-networkd`'s
state changes. **The consumer is switched on and the producer is not.** That is
this repo's recurring shape from a new angle: not a program that reported success
without changing anything, but a unit whose presence in the enabled set reads like
evidence that networking is configured, and is not.

The premise held for Ubuntu Server for a reason that does not apply here: there,
the DHCP default is written by `cloud-init` into `/etc/netplan/50-cloud-init.yaml`.
This image has no `cloud-init`. On amd64-GUI the gap is invisible because
`network-manager` ships `10-globally-managed-devices.conf` and takes every device
— which is exactly why it has never been seen, and exactly why arm64 and
amd64-headless would hit it.

### M1 — and the machine is worse off than the image said

Everything above is a property of a squashfs, so the claim "an installed arm64
machine comes up with no network" was a *prediction*. **It was measured the same
day, and it holds.**

A disk installed by a **pre-Phase-3b** build (`.vm/phase3`, 2026-08-24), booted
alone with no ISO attached and a virtio NIC present, logged into over the serial
console and asked:

```
2: enp0s2: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN
ip -o addr show          1: lo  inet 127.0.0.1/8      (and nothing else)
ip route show            (empty)
systemctl is-enabled systemd-networkd        disabled
systemctl is-active  systemd-networkd        inactive
systemctl is-enabled networkd-dispatcher     enabled
ls -A /etc/netplan/                          (empty)
ls -A /run/systemd/network/                  EMPTY
dpkg -l network-manager                      un  (not installed)
```

**The interface is DOWN with `qdisc noop`, it has no address, and the routing
table is empty.** Not "DHCP did not answer" — the link was never brought up. The
machine is unreachable and nothing on it reports a problem.

And the shape this session started from is there in one line pair:
`networkd-dispatcher` **enabled**, `systemd-networkd` **disabled and inactive**.
The consumer is switched on and the producer is not.

That settles the phase's priority. Screen 9 is not a convenience: every headless
arm64 machine this installer has produced needed a keyboard and a monitor to be
reached.

**What M1 does not say.** One machine, arm64, in QEMU, from one build. It says
nothing about amd64, where `network-manager` is installed on the GUI product and
would have brought the link up by itself — which is precisely why this went
unnoticed for so long — and nothing about hardware whose driver behaves
differently from `virtio_net`.

**M2** (what recovery looks like on a machine with a locked root) and **M3** (the
amd64 half — whether the headless purge really takes `network-manager`) are still
owed.

### One methodological failure worth recording

The first attempt at M1 was a throwaway script that drove the serial console
itself instead of going through `vmconsole`'s `live_login` and `to_plain_bash`.
It reached a login, and then every command came back as mojibake and a PowerShell
error: the login shell on an installed OS/7 machine is `pwsh`, and bash syntax
typed into it does not merely fail — an unanswered terminal query corrupts the
session. That is BUILD-NOTES #16, which this repository already knew and had
already wrapped in two helper functions.

The measurement was obtained only after rewriting the probe to use them, which is
what `run-phase3b-network.py m1` now is. Recorded because "a quick throwaway
probe" is exactly how a repository's hard-won helpers get bypassed, and the
second attempt cost more than using them would have.

---

## The Wi-Fi question, answered with a price

The question was whether to put a Wi-Fi screen into Setup at all. The manifests
turn it into arithmetic:

* **amd64: zero packages.** `wpasupplicant`, `iw`, `rfkill`, `modemmanager` and
  `network-manager` are all already on the ISO, via the desktop.
* **arm64: three packages, about 4 MB** — `wpasupplicant`, `iw`, `rfkill`.
* **Firmware: already on both.** 19 `linux-firmware*` packages covering Intel,
  Broadcom, Realtek, MediaTek, Qualcomm and Marvell. This is the part that is
  large and that cannot be fetched later without the network it is needed for, and
  it is paid for already.

The expensive part is not the packages, it is the verification. A Wi-Fi
passphrase written blind to a headless machine that turns out to be wrong is the
site visit [RELEASE-AND-UPDATE-PLAN §4.4](RELEASE-AND-UPDATE-PLAN.md) exists to
avoid. That is why D12 puts live application and testing in the same screen as the
target write, and why the beneficiary of the Wi-Fi screens is mostly the headless
product — the amd64 GUI has GNOME's own network UI.

802.1X (PEAP/MSCHAPv2) is in v1 because the product's users are
Microsoft-administered fleets and a corporate WLAN is 802.1X far more often than
it is PSK. Its cost is honest and is written down as L27: there is no certificate
store in 80×25, so server verification is a file path or a printed absence.

---

## The account model — nothing changes, and that is the result

`SystemSteps` already creates one account with `useradd -m -s /bin/bash -G sudo`
and never gives root a password, so root keeps the `!` it has in the base image.
The question asked was whether to add a root password. The answer is no, and it
now has three reasons instead of being an inherited default (D11):

1. **Ubuntu's.** No root account to brute-force, `sudo` logs each command under
   the human's name, rights move by group membership.
2. **`authd`'s.** The Entra broker makes the first user to authenticate the
   **owner**; `owner_extra_groups = sudo` grants administration and
   `allowed_users = OWNER` is the default. Admin rights are meant to arrive from
   the tenant.
3. **The fleet's.** A root password cannot be rotated across 500 machines, appears
   in no audit trail, and lives outside the tenant that is supposed to be the
   authority on the device. Offering it as an *option* would be worse than either
   extreme, because then nobody can say which machines have one.

What the plan adds is a **name for the role**: the local account is the
break-glass credential, the one that still works when Entra is unreachable. Screen
7 currently calls it "the account that administers this machine", which invites an
operator to treat it as a throwaway first user.

### A limitation found on the way

**A rollback un-says a local password change (L26).** `/etc/shadow` is inside the
boot environment, so a password changed after install is reverted with `/usr` when
a boot environment is rolled back. D10 moved the Entra/Intune/Arc agent state
*out* of the BE precisely because the tenant on the other end has no rollback —
the mirror-image case, the local credential that a rollback quietly reverts, was
not considered at the time. It is not fixed here and may not be worth fixing:
moving `/etc` out of the BE is the split L21 warns about.

---

## The sharp technical point: the renderer

Netplan needs a backend, and which one is correct is decided by screen 8:

| Product | Renderer | Why |
|---|---|---|
| amd64, GUI | `NetworkManager` | NM is installed and owns every device |
| amd64, headless | `networkd` | the headless path's `apt-get autoremove -y --purge` removes `network-manager` |
| arm64 | `networkd` | NM was never installed |

So the renderer must come from `plan.Mode`, **never** from probing the target for
`network-manager` — probing gives a different answer depending on whether the
purge has run yet, which makes an installed machine's network depend on step
ordering rather than on the plan (L24). The network step also runs *after* the
mode step, for the same reason.

And the check is not an exit code. `netplan apply` cannot run in a chroot, but
`netplan generate` can, and it produces
`/run/systemd/network/10-netplan-<iface>.network`. Setup reads that file back and
asserts `DHCP=ipv4` or the `Address=` that was typed. That diagnostic needs no
running networkd, no link and no DHCP server — **it does not depend on the
subsystem it is diagnosing.**

---

## What this changes in the plan

All of it is in [SETUP-PLAN.md](../installer/SETUP-PLAN.md):

* **§3** — screen 9 gains 9S (static TCP/IP) and 9W (Wi-Fi), lettered rather than
  numbered so nothing downstream renumbers (BUILD-NOTES #45). Screen 9's position
  after screen 8 is made load-bearing rather than incidental.
* **§3.1** — mockups for 9, 9S and 9W.
* **§7.1** — `wpasupplicant`, `iw`, `rfkill` for arm64.
* **§7.2** — new: the measured network stack, the renderer table, live-vs-target,
  and what must never enter the plan file.
* **§7.3** — new: the account model, with `authd`'s owner mechanism written down.
* **§8** — L23 through L28.
* **§9** — D11 (account model), D12 (live *and* target), D13 (Wi-Fi with 802.1X),
  D14 (renderer from `plan.Mode`).
* **§10** — Phase 3b, with M1–M3 ahead of any code, and the testing contract.
* **§12** — the seven new verified claims, each with the file or page it came from.

Phase 3's own paragraph about screen 9 is **annotated rather than rewritten**. The
reasoning it contains was sound about Ubuntu and was never asked of this image,
and that shape is worth keeping visible.

---

## What was built after the plan

`NetworkPlan` and `WifiPlan`; `NetworkLinks` (adapters from `/sys/class/net`, and
an `iw scan` parser separable from the command so it can be fed a recording);
screens 9, 9S and 9W; `NetworkProbe` (the live apply behind `F4`) and
`NetworkStep` (the target write); `--test-network` and `--wifi-secret-file`;
24 new `--self-test` assertions; `run-phase3b-network.py`, and `run-phase3.py`'s
walk extended through screen 9.

**Six defects were found by those checks before a machine could have found them**,
and the kind of check that caught each is the transferable part:

| Found by | Defect |
|---|---|
| a captured `iw scan` fed to the parser | `iw` escapes a hidden SSID as the literal text `\x00\x00…`, not as NUL bytes. A `c == '\0'` filter caught nothing |
| running the generated shell with its targets absent | `set -euo pipefail` killed the diagnostic three lines before its own `echo`. Demonstrated: the pre-fix script exits 1 with **no output at all**. `bash -n` passes it |
| reading SetupFlow's order against the code | the Wi-Fi scan blocked before the screen it was scanning for was drawn — under a comment claiming the opposite |
| asking what the walk VM actually had | the walk VM had **no NIC**, so screen 9 would have been skipped and the walk would have reported success |
| serialising four canary secrets | nothing leaked — but nothing had ever checked, and a removed `[JsonIgnore]` has no symptom |
| looking inside the squashfs | "no `linux-modules-extra`, therefore no wireless drivers" is a plausible inference from the package list and is **wrong**: 197 wireless driver modules are present, `mac80211_hwsim` among them |

## L30 — the interface name changes between installing and running

**The most expensive thing this phase learned, and it was found only because the
deliverable was checked on a booted machine rather than on the disk it had just
been written to.**

The install wrote a netplan file naming the adapter the harness had discovered.
Then the disk was booted alone:

```
installing, setup medium attached      enp0s5
booted from the disk, medium removed   enp0s2
MAC, throughout                        52:54:00:12:34:56
```

One machine, one NIC, two names. Predictable interface names are derived from the
PCI topology, and **the setup medium is a PCI device** — removing it renumbers
the slots. The file named `enp0s5`, which no longer exists.

netplan accepts a match that matches nothing. The installed machine came up:

```
2: enp0s2: <BROADCAST,MULTICAST> qdisc noop state DOWN
ip -o addr show    1: lo  inet 127.0.0.1/8   (and nothing else)
ip route show      (empty)
```

That is, line for line, the M1 transcript this phase exists to abolish. **Screen 9
would have written a file, proved that netplan turned it into a valid networkd
unit, reported success, and produced exactly the machine it was built to
prevent.**

### Why none of the checks saw it

| Check | What it said | Why it was no help |
|---|---|---|
| `--self-test` on the generated YAML | correct | It named a real interface — just not the one that would exist later |
| `netplan generate` in the chroot | a valid networkd unit | A unit that matches nothing is still a unit |
| reading that unit back for `Address=` | present | On an interface that would not exist |

Every check was right, and every one was about the wrong moment. The only
instrument that could see this was a machine booted with the medium removed —
which is exactly why `run-phase3.py`'s `boot` phase attaches no ISO. Spike S3 made
that split for a different reason (a VM with the medium still in it can boot from
the medium and look like a successful install), and this phase inherited it
without understanding how much else it was protecting.

### The fix

`match: macaddress:`, never the name. A MAC does not move when a disk is
unplugged. The netplan device id is `os7net` and not an interface name, because
an id that looks like a name invites the next reader to believe the name selects
the hardware. `Interface` is still recorded — it is what the operator saw on
screen 9, and what the log and screen 12 should say — but it selects nothing.

`"interface": "auto"` keeps its `en*` / `wl*` glob for a plan replayed on hardware
Setup has never seen, and a MAC in the plan beats it.

### Three more, found on the way

* **Three QEMU processes leaked.** `poweroff` asks the guest; it does not
  guarantee the process leaves, and a phase that fails never reaches the request.
  The symptom was not a slow Mac — the next run could not open its own disk
  image, because qemu holds a write lock on it. A previous session left one alive
  for 13h50m, so this is a repeat rather than a surprise.
* **Every chroot step was proving its work to an empty room.** `Executor.Exec`
  captures a subprocess's stdout with `ReadToEnd` and never prints it, so
  `AccountStep`'s `/etc/shadow` proof, `InitramfsStep`'s contents listing and
  `NetworkStep`'s unit readback all went into a string nobody looked at.
  `TargetRoot.Chroot` now logs it. Found by a harness assertion watching the
  serial console for a line the console structurally could not carry: the
  assertion was wrong, the gap it revealed was not.
* **Nothing copies the install log onto the target.** `Log.Directory` is an
  absolute path on the live system, which is casper's RAM overlay, so the entire
  record of what Setup did is discarded at the reboot on screen 12 — including
  every proof above. On a machine that boots correctly nobody misses it; on one
  that boots wrong, the log that would explain it is already gone. Spun off as
  its own task rather than widened into this one.

---

## Owed, and not done

* **M2 and M3.** M1 is measured (above). M2 is what recovery looks like on a
  machine with a locked root; M3 is the amd64 half of L23 and L24.
* **amd64 is entirely unmeasured.** Everything here is arm64. `os7-d7` measured
  on the same day that `os7-setup` on amd64 is not *absent* but *displaced* — it
  starts, wins tty1, paints, and the desktop takes the console afterwards. Screen
  9 on amd64 would compete with `gdm3` for the same screen, and no arm64 run can
  say anything about that.
* **802.1X is written and unproven.** PEAP/MSCHAPv2 is generated configuration
  and a screen walk. Testing it needs an EAP server; `hostapd` has one and is not
  on the image, and putting it there to test a feature would be adding to the
  product for the test's benefit (D13).
* **The Wi-Fi test proves no firmware.** `mac80211_hwsim` simulates the hardware
  layer away and loads none. 19 firmware packages and 197 drivers are on the
  image and not one has been exercised.
* **BUILD-NOTES** — the "consumer enabled, producer not" trap and the `iw`
  escaping trap both deserve numbers, and neither was written here. `os7-d7` holds
  #50 and #51 for them in the file's own claiming table, and will write them when
  a measurement of their own stands behind each. Citing this session's would be
  the exact mistake the first entry describes.

---

## Parallel sessions

This work was done in the worktree `.claude/worktrees/setup-network-accounts`,
because `os7-d7` was working on the amd64 boot path **in the main working tree on
`main`** at the same time. Two sessions with uncommitted changes in one working
tree is not a merge conflict — git says nothing at all. `os7-f7` was idle and
held nothing.

`os7-d7` also supplied two constraints this plan respects: `run-phase3.py walk`
counts screens by keypress, so inserting one shifts the walk; and `CMDLINE` is
duplicated verbatim in `run-phase1/2/3.py` and `efi-remaster.sh`, so any change
touches four files. The three-package addition to
`build/config/package-lists/os7-base.list.chroot` is in `os7-d7`'s tree and is
listed in Phase 3b as needing coordination, not as done.
