# The amd64 EFI remaster — one script for both arches, and what the first boot said

**Date:** 2026-08-25, against `main` at `c4b3ddb`. Follows
[SESSION-AMD64-FIRST-ISO.md](SESSION-AMD64-FIRST-ISO.md), which ended with an
amd64 ISO that could not boot and named this as the next task.

**The medium boots.** Firmware → GRUB → OS/7's menu, on amd64, measured. **What
it boots into was wrong**, and that is the more valuable half of the result.

---

## What was built

`build/lib/arm64-efi-remaster.sh` became
[`build/lib/efi-remaster.sh`](../build/lib/efi-remaster.sh) and took an
architecture argument. Only three things differ:

| | arm64 | amd64 |
|---|---|---|
| `grub-mkstandalone --format` | `arm64-efi` | `x86_64-efi` |
| loader | `BOOTAA64.EFI` | `BOOTX64.EFI` |
| GRUB modules, embedded cfg, menu, FAT ESP image, xorriso line, volid | shared | shared |

A 160-line copy was the alternative, and the thing being copied is the GRUB menu
of SETUP-PLAN §7 — the screen a person sees before OS/7 is installed. Two copies
of that drift, and the drift is invisible because nobody boots the other
architecture on the way past.

`build/build.sh` no longer branches on architecture. live-build's own ISO is
discarded on both now, for reasons that finally rhyme: arm64 never got a
bootloader, amd64 got syslinux — BIOS, from a stage that cannot run against a
2026 archive at all (BUILD-NOTES #47).

## Proving the refactor did not change arm64

The obvious check gives a wrong answer, and the control is the whole experiment.
Old ISO vs new ISO: different hashes. Old ISO vs **old ISO**: also different —
`xorriso` stamps a creation time into the PVD. A hash comparison across this
refactor can only ever return "different".

What can be compared, and was:

* `grub.cfg` — `diff`: identical.
* the EFI binary — `grub-mkstandalone` **is** deterministic: three runs, same
  6811648 bytes, same SHA-256. The payload that boots the machine is provably
  unchanged even though its container is not.
* the ISO structure — `xorriso -report_el_torito plain -find /`, dates filtered:
  **no difference**.

Then the real check, on a real artefact: `make build-arm64` locally →
`OS7-1.0.0.46-arm64.iso` → `check-image.py arm64` all green →
`run-phase1.py all` **4/4 PASS** (live, boot, walk, contrast). BUILD-NOTES #48.

## The first amd64 boot

`qemu-system-x86_64`, edk2, TCG on Apple Silicon — no hvf for x86, so this is
emulation and slow. It answers one question: does the medium boot?

```
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
GNU GRUB  version 2.14
*Install OS/7 (amd64)
```

Yes. Firmware found `/EFI/BOOT/BOOTX64.EFI`, GRUB loaded, the menu is OS/7's,
the default entry is Install. Everything the remaster is responsible for works.

**And then the Install entry came up in a GNOME desktop.** Walking the VTs at
200 s found `os7-setup` on none of them — tty1 blank grey (the display manager's),
tty2 the GNOME session, tty3 a plain `ubuntu login:`.

**That reading was wrong, and photographing earlier corrected it.** At 95 s the
Welcome screen is there, painted, version 1.0.0.47. At 310 s the desktop is in its
place. Setup is not absent; it is **displaced**. The VT walk had looked after the
hand-over and read one moment's absence as a cause. Read out of the image afterwards, no VM: the unit
is present, its `ConditionKernelCommandLine=os7.setup=1` is satisfied, and
`/etc/systemd/system/display-manager.service -> gdm3` is enabled. Both correct in
isolation; the Install entry takes tty1 and `graphical.target` takes the screen.
**arm64 is server-only and has no display manager, so nothing on arm64 could ever
have exposed this.** BUILD-NOTES #49.

The fix is `systemd.unit=multi-user.target` on the Install entry — inert on
arm64, decisive on amd64 — and the live entry deliberately does not get it,
because on amd64 "try before you install" (L14) means a desktop.

## What was NOT measured

* ~~That the fix works.~~ **Measured**: `systemd.unit=multi-user.target` typed
  into GRUB's editor, same ISO, same VM — at 310 s the Welcome screen is still
  there, where the unmodified entry had a desktop. One run per condition, the
  parameter after `---` rather than in its shipped position, and 310 s is a
  moment rather than a guarantee.

  **And the shipped ISO carries it** — `OS7-1.0.0.48-amd64.iso` from CI run
  32854778263, read with `xorriso -osirrox on -extract /boot/grub/grub.cfg`:

  ```
  menuentry "Install OS/7 (amd64)" {
      linux  /casper/vmlinuz-7.0.0-30-generic boot=casper os7.setup=1 \
             systemd.wants=os7-setup.service systemd.unit=multi-user.target \
             fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 ---
  ```

  and the two live entries deliberately do not. `/EFI/BOOT/BOOTX64.EFI` is on the
  medium, 6828032 bytes.

  Two facts, two instruments: **that the line works** was measured in a VM, and
  **that the built ISO has it** was read out of the artefact. Booting the CI ISO
  would have mixed them, and would have been sensitive to the load of the other
  sessions building on this machine at the time.
* **Secure Boot.** The medium's GRUB is `grub-mkstandalone`'s and therefore
  UNSIGNED, on both architectures, and always has been. The ISO boots only with
  Secure Boot **off**. S4 and S6 tested the INSTALLED disk — shim plus a
  Canonical-signed GRUB on the ESP, a different boot path. This matters more on
  amd64, whose firmware ships with Secure Boot enabled. `shim-signed` and
  `grub-efi-amd64-signed` are already in the image; using them costs the
  embedded-config trick, because a signed GRUB has a fixed prefix and loads only
  signed modules. Open.
* **Nothing past the GRUB menu on amd64 beyond what is above.** No install, no
  walk, no `run-phase*` on amd64 — those harnesses are `qemu-system-aarch64`
  with `accel=hvf` throughout.
* **The x86 boot probe is a scratch script**, not a harness. It boots, waits,
  screendumps over QMP and can send `ctrl-alt-F<n>`. It is not in the repository.

## What it changes in the plan

1. **amd64 has a boot path**, so the next amd64 question is the first amd64
   *install* — and that needs an x86_64 harness, which does not exist.
2. **The Install command line now lives in four places** — `efi-remaster.sh` and
   `run-phase1/2/3.py` — and phase 1's own comment says what that costs: *"If
   these ever disagree, the harness is testing something the ISO does not do."*
   All four were updated together this time. They should be reading the line off
   the ISO instead.
3. **A Secure-Boot-bootable medium is now a named open item** rather than an
   unexamined assumption.
