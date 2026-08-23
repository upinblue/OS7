# OS/7 — handoff

**Written 2026-08-23.** State of the repo and the next steps, in order.
Everything here runs **locally on an Apple Silicon Mac**. No cloud, no CI, no
paid services.

---

## 1. What works today

| Thing | State |
|---|---|
| `make build-arm64` | **Works.** Produces `out/os7-arm64.iso`, ~2 GB. |
| That ISO boots | **Yes.** UEFI → GRUB → casper → systemd → login prompt, in QEMU. |
| **Installing to a disk** | **Works on arm64, proven end to end.** ZFS-on-LUKS root, installed from the live ISO and booted from the disk alone. See [SESSION-S3-ZFS-LUKS.md](SESSION-S3-ZFS-LUKS.md). |
| **Secure Boot + TPM2** | **Works on arm64.** Boots with SB enabled against the Microsoft UEFI CA; TPM2 auto-unlock works and a TPM-less machine still prompts. See [SESSION-S4-SECUREBOOT-TPM.md](SESSION-S4-SECUREBOOT-TPM.md). |
| PowerShell | **Works.** Login lands at `PS /home/…>`, on the live ISO and on the installed system. `Import-Module OS7` resolves by name and exports all three functions (they are stubs that throw by design). `bash` is still the login shell; `pwsh` is deliberately *not* in `/etc/shells`. |
| ZFS | **Works and is safe.** `zfs.target` reached on boot. See [SESSION-0-ZFS-VALIDATION.md](SESSION-0-ZFS-VALIDATION.md). |
| arm64 server-only split | **Works.** No GNOME/gdm3/Edge/Intune in the arm64 image. |
| `make build-amd64` | **Blocked locally.** See §3. |
| `os7-setup` | **Does not exist yet** — not a skeleton, not a stub. |

### S3 is done — the gate is open

`installer/SETUP-PLAN.md` §10 Phase 0 said S3 gated everything, because the repo
had never installed OS/7 to a disk by any means. It has now:

```bash
./installer/spikes/run-s3.py all
```

partitions a blank disk (ESP + `bpool` + LUKS2), creates `bpool` and `rpool`,
lays down the §4.4 datasets, `unsquashfs`es the live filesystem into them,
configures the target and installs GRUB — then reboots **from the disk alone**,
asks for the passphrase, and reaches a login prompt with `/` served from
`rpool/ROOT/os7_2026.08.1_202608230935`. Roughly 15 minutes on Apple Silicon.

* the sequence: [`installer/spikes/s3-zfs-luks.sh`](../installer/spikes/s3-zfs-luks.sh)
  — throwaway in quality, load-bearing in **order**; `os7-setup`'s storage
  executor is meant to be a front-end over exactly this
* the harness: [`installer/spikes/run-s3.py`](../installer/spikes/run-s3.py)
* the findings: [SESSION-S3-ZFS-LUKS.md](SESSION-S3-ZFS-LUKS.md)

**The one thing to carry into every later boot problem:** a ZFS root needs
**`boot=zfs`** on the kernel command line and *nothing generates it for you* —
not `initramfs-tools`, not `grub.d/10_linux_zfs`. Without it the machine drops
to an initramfs prompt. BUILD-NOTES #15.

## 2. Do this next

Phase 0 has **two spikes left** — S1 and S2 — and SETUP-PLAN gates Phase 1 on
all four. S3 and S4 are done.

**S1 (the look) and S2 (NativeAOT in the build container) are independent** of
each other and of everything above, so either can go first.

* **S1** wants the framebuffer palette specifically, so it needs
  `-device virtio-gpu-pci` and `screendump` from the QEMU monitor — the S3/S4
  harnesses deliberately run with `-display none`. `installer/spikes/vmconsole.py`
  gives you the console driving; the display plumbing is new work.
* **S2** is `dotnet publish -p:PublishAot=true` in `os7-build` for both arches.
  It needs no VM at all.

**Then Phase 1** — the `os7-setup` skeleton, strictly non-destructive.

### What S3 and S4 changed about what Setup has to do

* **`boot=zfs` is mandatory** on the kernel command line and nothing generates
  it. BUILD-NOTES #15.
* **Never pin `root=ZFS=` in `GRUB_CMDLINE_LINUX`.** `10_linux_zfs` emits one
  per boot environment and anything appended there wins, so every entry in the
  menu would boot the same dataset.
* **L4 may be smaller than SETUP-PLAN assumes.** `10_linux_zfs` still ships and
  generated correct entries unassisted — but it emits zsys-era "Revert" entries
  OS/7 has no `zsys` to serve, and titles the menu **"Ubuntu 26.04 LTS"** from
  `/etc/os-release`. Menu branding is entangled with D8/L16.
* **Setup cannot set a password through PAM in the chroot**, and the squashfs
  has no users at all. BUILD-NOTES #17.
* **Do the chroot's bind mounts inside `unshare --mount --propagation
  private`**, or the pool will not export. BUILD-NOTES #18.
* **TPM2 enrolment is more than `systemd-cryptenroll`.** It writes a valid
  token and changes nothing at boot; Setup must also install an initramfs hook
  carrying the token handler **and the libtss2 libraries systemd dlopens**, plus
  a `local-top` script that runs before `cryptroot`. BUILD-NOTES #19 and #20;
  `installer/spikes/s4-tpm-enroll.sh` is the working version.

### The two open risks S4 leaves behind

* **PCR 7 sealing has no recovery story.** Sealing survives kernel and initramfs
  updates, but **not** a Secure Boot policy change — a shim or dbx update drops
  every machine back to the passphrase prompt. On a managed fleet that is a
  support event, and nothing here addresses it.
* **L18 is still untouched.** Whether Intune's encryption check accepts the
  unencrypted `bpool` needs a real enrolment, not a VM.

## 3. amd64 — why it fails here, and the two local options

`make build-amd64` dies unpacking the base system:

```
E: Tried to extract package, but tar failed. Exit...
tar: ./etc/default: Cannot mkdir: Function not implemented
```

`Function not implemented` is `ENOSYS`. It is **not** an OS/7 bug and not the
VirtioFS problem in BUILD-NOTES #3 — it happens in a container-local path.
Docker Desktop's *syscall-translation* emulation lacks a syscall GNU tar 1.35
uses. Proven by A/B: the identical extraction exits 0 on native arm64 and 2
under amd64 emulation, while coreutils and Python's `tarfile` both work.

Still present on Docker **29.7.2**.

**Do not** work around it by swapping the extractor. That mishandles ownership,
device nodes and xattrs — you get a subtly broken rootfs instead of an honest
failure.

**Which command to run depends on the host:**

| Host | Command |
|---|---|
| **x86_64** — Intel/AMD Mac, x64 Windows, x86_64 Linux | `make build-amd64` — native and fast |
| **arm64** — Apple Silicon | `make build-amd64-vm` — full QEMU x86 VM, hours |

`make build-amd64` refuses early on a non-x86_64 host and points at the VM
target, so you cannot accidentally spend 20 minutes reaching a known failure.

The VM works because QEMU emulates a whole x86 machine rather than translating
syscalls. `scripts/build-amd64-vm.sh` does everything: fetches and
checksum-verifies the cloud image, provisions it with cloud-init, copies the
repo in over SSH, builds, and copies the ISO back to `out/`.
`make build-amd64-vm-reset` discards the VM.

Worth one minute first: Docker Desktop → Settings → General → "Use Rosetta for
x86_64/amd64 emulation on Apple Silicon" is at its default (no key in
`settings-store.json`). Flipping it selects a different emulator which may
implement the missing syscall; if it does, plain `make build-amd64` works here
again.

Until an amd64 ISO is actually built, **amd64 is unvalidated** — and since GUI
mode is amd64-only, the entire GUI path is unvalidated with it. **S3 is an arm64
result only**, for the same reason.

## 4. Traps that already cost time — read before debugging

Full detail in [BUILD-NOTES.md](BUILD-NOTES.md). The ones that bite hardest:

- **#13 — hooks must be at `config/hooks/*.chroot`, FLAT.** The older
  `config/hooks/normal/` layout does not match; live-build then runs nothing,
  prints "Begin executing hooks...", and **exits 0**. `build.sh` now hard-fails
  if hooks are authored but none stage. Never conclude a hook ran because the
  build succeeded — check the image for its effect.
- **#14 — PowerShell module discovery is broken inside `chroot(2)`.** It probes
  `PSModulePath` with the character at index 1 dropped (`/opt/...` → `/pt/...`).
  Build-time only; the shipped image is fine. So no hook can test anything
  needing discovery — `Write-Host`, `Get-Module -ListAvailable`, or
  `Import-Module <name>`. Import **by path** works and is what hooks check.
- **#15 — a ZFS root needs `boot=zfs`, and nothing puts it there for you.**
- **#16 — driving a serial console:** Enter is `\r`, not `\n`, and an
  *unanswered* terminal query kills PowerShell outright. Also: never expect a
  marker that the typed command itself contains, or the shell's echo will match
  it and report success for a command that never ran.
- **#17 — `chpasswd` cannot work in a chroot on this image**, and the squashfs
  contains no users at all.
- **#18 — `mount --make-private --rbind` is not enough for an installer
  chroot.** The bind propagates to other namespaces before it is made private,
  and `zpool export` then says *"pool is busy"* with nothing mounted and `-f`
  powerless. Do the binds and the chroot inside
  `unshare --mount --propagation private`.
- **#19 — `systemd-cryptenroll` alone does nothing at boot**, and fails
  silently: `cryptsetup-initramfs` has no concept of LUKS2 tokens.
- **#20 — `copy_exec` cannot see a dlopen.** systemd dlopens the whole TPM
  stack, so an initramfs built by walking ELF `NEEDED` gets the token handler
  and no libtss2 at all.
- **#21 — Homebrew's QEMU has no Secure-Boot aarch64 firmware.** `run-s4.py`
  pulls Ubuntu's `qemu-efi-aarch64` out of the build container instead. Expect
  10–15 minutes per boot: AAVMF renders GRUB's countdown on a 238-column serial
  console.
- **`pwsh --version` is not a health check.** The banner, `Import-Module` by
  path and `Get-Command` are compiled into the binary and succeed while the
  whole on-disk module tree is unusable.

And the rule the whole episode argues for:

> **A diagnostic must not depend on the subsystem it is diagnosing.**

Three diagnostics broke that rule; two produced a confident but **false** "the
directory is empty" reading that sent the investigation after a filesystem bug
that did not exist. Filesystem facts come from `bash`; PowerShell facts use pure
.NET.

S3 added its sibling, and it is just as expensive:

> **A diagnostic must be checked against the thing it claims to check.**

The S3 script asserts that the generated initramfs can really unlock and import.
It reported `MISSING conf/conf.d/cryptroot` on an image that was perfectly fine:
that is the pre-2.x path, and `/lib/cryptsetup/functions` sets
`TABFILE=/cryptroot/crypttab` at initramfs stage. The check now uses the real
path **and prints what the initramfs actually contains**, so a wrong expectation
shows as a mismatch instead of a verdict. Keep that assertion — it is the
difference between "the boot failed" and "the boot failed *because the unlock
config never made it in*", and it costs seconds instead of a boot cycle.

## 5. Verifying a built ISO — the fast way

Do **not** drive the boot over QEMU's serial console by hand. Bytes sent faster
than the console consumes arrive corrupted, and PSReadLine's rendering makes
capture worse; several attempts produced garbage. `installer/spikes/run-s3.py`
shows what it takes to do it reliably anyway (BUILD-NOTES #16) — read freely,
type one character at a time, re-send a step whose acknowledgement never
arrives, and answer the terminal's queries.

For everything that is not "does it boot", mount the squashfs and run the
image's own binaries — fast, clean, quotable:

```bash
docker run --rm --privileged --platform linux/arm64 -v "$PWD/out":/iso os7-build:arm64 bash -c '
  mkdir -p /mnt/iso /mnt/sq
  mount -o loop,ro /iso/os7-arm64.iso /mnt/iso
  mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq
  # inspect /mnt/sq, or run /mnt/sq/opt/microsoft/powershell/7/pwsh directly
'
```

## 6. Open items not decided anywhere

- **The live ISO and the setup ISO are currently the same image.** SETUP-PLAN §7
  has Setup running from the live medium. If they are meant to diverge, that
  needs deciding before Phase 1.
- **dash-to-panel / ArcMenu have no GNOME 50 build** in the resolute archive, so
  the "familiar desktop" goal is unmet on amd64. Hook 0070 logs the gap.
  Options are in BUILD-NOTES.
- **D8/L16 — `/etc/os-release` identity.** Still undecided, and S3 gave it a
  second face: the GRUB menu entry is titled from `PRETTY_NAME` and currently
  reads "Ubuntu 26.04 LTS".
- **`/var` mounts via `zfs-mount.service`, not `zfs-mount-generator`.** It
  works, and the datasets all landed on their real mountpoints with no altroot
  leakage — but there is no `zfs-list.cache`, so ordering under load has not
  been tested.

## 7. Repo orientation

```
build/config/auto/config          live-build config (DISTRIBUTION=resolute)
build/build.sh                    staging + orchestration; read its comments first
build/config/package-lists/       common packages
build/config/package-lists-{amd64,arm64}/   arch-specific
build/config/hooks/               common hooks, FLAT (see trap #13)
build/config/hooks-amd64/         amd64-only hooks
build/lib/arm64-efi-remaster.sh   arm64 has no live-build bootloader; this fixes it
powershell/OS7/                   the OS7 module - ONE source of truth, staged by build.sh
installer/SETUP-PLAN.md           the installer design and decisions. Authoritative.
installer/spikes/s3-zfs-luks.sh   the proven install sequence (S3)
installer/spikes/s4-tpm-enroll.sh TPM2 enrolment + the initramfs pieces (S4)
installer/spikes/run-s3.py        QEMU harness for S3
installer/spikes/run-s4.py        QEMU harness for S4 (Secure Boot + swtpm)
installer/spikes/vmconsole.py     serial-console driving, shared by both
docs/SESSION-S3-ZFS-LUKS.md       what S3 proved, and the nine things it depends on
docs/SESSION-S4-SECUREBOOT-TPM.md what S4 proved, and what it deliberately does not
docs/BUILD-NOTES.md               every trap found so far. Read before debugging.
.vm/s3/, .vm/s4/, .vm/firmware/   VM state, serial logs, AAVMF (all gitignored)
```
