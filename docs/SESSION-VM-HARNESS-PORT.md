# Session — the VM harness runs on the x64 Windows host

**2026-08-28, on the x64 Windows host.** Every `run-*.py` harness was
`qemu-system-aarch64 -machine virt,accel=hvf` — a sentence about one Mac. It
is now one module's decision (`installer/testing/vmarch.py`), and the amd64
branch has RUN: the first unattended amd64 installation this repository has
ever made, the first amd64 boot of a disk it installed, and the full S5
clone-activate-rollback cycle, all on this box, under KVM, inside a container.

The arm64 branch was **not executed** — no Mac took part in this session. What
holds it is `check-vm-arch.py`: the pre-port command lines of every harness,
reproduced literal for literal from commit 8700095 inside the check itself,
with the refactored code required to emit byte-identical argv (19 checks),
plus 22 property checks on the amd64 half. It needs neither QEMU nor Docker
and runs on both hosts.

---

## 1. The design, and the one genuinely different thing

| | arm64 | amd64 |
|---|---|---|
| binary | qemu-system-aarch64 | qemu-system-x86_64 |
| machine | virt, **HVF** | q35, **KVM** |
| firmware | AAVMF (brew) | OVMF (non-SB build, in-container) |
| serial | ttyAMA0 | ttyS0 |
| TPM frontend | tpm-tis-device (sysbus) | tpm-tis (LPC) |
| runs as | **host process** | **inside `os7-vm:amd64`** |

The last row is the port, not the renames above it. This host has no QEMU and
no KVM of its own — both live in Docker Desktop's WSL2 VM — so QEMU runs in a
container (`Dockerfile.vmhost`: qemu-system-x86, ovmf, swtpm, xorriso,
python3) and the harness drives the **docker client's stdio**, which is the
same pipe `Console` always spoke: `-serial stdio` through `docker run -i`.
Three consequences, each handled in vmarch.py so no harness knows:

* **Paths** are translated through a registered mount table; a path under no
  mount is refused with a message that names the file, because the failure
  mode of a guess is QEMU saying "no such file" about a file that exists.
* **Sockets** cannot live on Docker Desktop's Windows file sharing (bind(2)
  is refused). QMP moved to TCP on a published localhost port; swtpm runs in
  the SAME container as QEMU with only its state directory on the mount.
* **Lifetime**: killing the docker client does not kill the container.
  Deterministic names, a `docker rm -f` preflight, and an atexit sweep.

`run-s5.py` needed two things beyond the mechanics, both measured:

* **`serialize`** — an installed amd64 machine says NOTHING on ttyS0 (#99):
  x86 has no device-tree `chosen` node, so the kernel console defaults to
  tty0. The harness gives the machine `console=ttyS0,115200` through its own
  `update-grub`, inside `unshare --mount --propagation private` (the first
  attempt re-measured #18). Whether the PRODUCT should ship a serial console
  on the server image is §6-adjacent and left open, not decided by a harness.
* **8 GiB guest memory on amd64** (arm64 keeps its proven 4096): the amd64
  medium is the GUI product and #79 is what a desktop workload does to a
  tight install. The memory floor was not measured; the value is pinned in
  `check-vm-arch.py` so it cannot drift silently.

## 2. What was measured, on this host

All against `OS7-1.0.0.116-amd64.iso`, QEMU 10.2.1, KVM
(`query-kvm → {"enabled": true, "present": true}`, re-measured this session).

* **`run-s5.py install` — PASS.** Unattended install with swtpm attached:
  the guest saw `/sys/class/tpm/tpm0`, all 17 os7-setup steps completed,
  both pools exported. The first amd64 install not made by a human.
* **`run-s5.py boot` — PASS, and the interesting half is the failure it
  contains.** The FIRST boot asked for the passphrase: the install-time seal
  is against the live session's PCR 7 and the installed machine boots
  through shim — **#69's prediction became a measurement (#100)**. The
  harness performs S6's recovery (one `systemd-cryptenroll` on the booted
  machine) and the next boot unlocked with nothing typed. Every curation
  check (C2, §4.2, the 19 wireless directories) passed on the installed
  amd64 machine for the first time.
* **`run-s5.py cycle` — PASS, 9/9.** Clone, assemble, `apt-get install
  hello` in the chroot, activate, boot the clone, roll back, boot again:
  the package un-said, the file written into `/home/os7admin` from the clone
  still there. **That last line is the first machine-level confirmation of
  the #74 home-dataset fix** — `/home/os7admin` is a `rpool/USERDATA`
  dataset on a booted machine and survives the rollback. `run-phase3.py all`
  on the Mac remains the full gate for #74 (checks 9 and 10 cover skel and
  ownership on a FRESH boot); this session confirmed the property the layout
  exists for.
* **`check-vm-arch.py` — GREEN, 19 + 22 checks** (the arm64 goldens and the
  amd64 properties, incl. no-host-path-leak and the memory pins).

## 3. What was expressly NOT measured

* **The arm64 branch was not executed.** Byte-identity to the pre-port
  construction is proven by `check-vm-arch.py`; that the identical bytes
  still boot a Mac's VM is one `./installer/testing/run-s5.py all` on the
  Mac away, and until it runs, "the arm64 path is unchanged" is a statement
  about argv, not about a boot.
* **run-backup.py, run-zfs.py, run-phase1/2/3, run-phase3b, verify-console-
  font** were ported mechanically (same vmarch seams) and none was RUN — on
  either host. The screen-driving harnesses additionally boot the medium
  through its own GRUB or use QMP screendumps; the amd64 CD/GRUB serial
  behaviour is unknown, so their amd64 readiness is "compiles and passes the
  golden check", nothing more.
* **The amd64 memory floor** (see §1) and swtpm-under-AAVMF quirks on the
  new path: the two swtpm flags are carried verbatim from run-s4; whether
  OVMF needs them was not isolated — the TPM demonstrably works with them.
* **Wall-clock**: the amd64 install ran in about 25 minutes end to end; no
  arm64 comparison was taken.

## 4. What this changes in the plans

* CLAUDE.md's host table: the x64 Windows box now runs `run-s5.py` (and
  loses the "no run-*.py harness runs here" row) — updated in this change.
* HANDOFF §2's "an x86_64 harness that does not exist … the single piece
  that unblocks both" is built; what the Mac still owes is listed there.
* `docs/HANDOFF.md` §1: run-s5 rows gain the amd64 measurements above.
