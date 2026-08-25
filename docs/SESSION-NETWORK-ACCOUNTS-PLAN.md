# The network screen, and the account model — planned, and one premise overturned

**Date:** 2026-08-25. Against `main` at `c4b3ddb`, "The amd64 Install entry booted
into GNOME, and only a boot could have said so", and the two ISOs built from that
line: `OS7-1.0.0.46-arm64.iso` and `OS7-1.0.0.47-amd64.iso`, both on archive
snapshot `20260824T000000Z`.

**This session wrote no installer code.** It measured, it planned, and it found
one sentence in [SETUP-PLAN.md](../installer/SETUP-PLAN.md) that is true of Ubuntu
and false of this image.

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

### What this is NOT evidence of

**No installed OS/7 machine has been booted with a NIC attached.** Everything
above is a property of a squashfs. The claim "an installed arm64 machine comes up
with no network" is a *prediction* from it, and this repo does not let a
prediction stand where a boot is available. It is recorded as **M1** in Phase 3b
and it runs before any code is written, because it is also the measurement that
decides whether the phase is urgent or merely tidy.

Two more are owed and are recorded with it: **M2**, what recovery looks like on a
machine with a locked root, and **M3**, whether the headless purge really takes
`network-manager` with it.

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

## Owed, and not done

* **M1, M2, M3** — the three measurements above. M1 gates the phase.
* **BUILD-NOTES** — the "consumer enabled, producer not" trap deserves a number.
  It was deliberately *not* written here: `os7-d7` added #44–#49 on the same day
  in the same tree, and two sessions choosing the next number independently is how
  a numbered list stops being one. It is owed to whoever holds BUILD-NOTES next.
* **No code.** No `NetworkPlan`, no screens, no steps, no harness. Phase 3b is
  planned and unstarted.

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
