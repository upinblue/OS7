# Phase 0 spikes

Throwaway scripts that answer one question each, from
[`../SETUP-PLAN.md`](../SETUP-PLAN.md) §10 Phase 0. **None of this is `os7-setup`
and none of it should grow into it** — no UI, no error handling worth the name,
no rollback. What survives a spike is its *sequence* and what it taught, not its
code.

| Spike | Question | State |
|---|---|---|
| **S1** | **Does the look actually work** | **PASS 2026-08-24 (arm64)** |
| **S2** | **Does NativeAOT build in the `os7-build` container** | **PASS 2026-08-23 (both arches)** |
| **S3** | **Does a ZFS-on-LUKS root install boot at all** | **PASS 2026-08-23 (arm64)** |
| **S4** | **Does it survive Secure Boot, and does TPM2 unlock work** | **PASS 2026-08-23 (arm64)** |

## S1

```bash
./run-s1.py font       build the console font and assert its coverage and shapes
./run-s1.py build      publish the NativeAOT painter for arm64
./run-s1.py palette    is the field exactly #0057ad          (two boots)
./run-s1.py mockup     the font, the glyphs and the §3.1 screens
./run-s1.py keys       press arrows and F-keys, check what decoded
./run-s1.py all        all five, in order    (~20 min, five boots)
./run-s1.py reset      discard the VM state
```

Needs `out/os7-arm64.iso` and `qemu-system-aarch64`. Screendumps land in
`../../.vm/s1/shots/` as PNGs; the VM state and serial logs are beside them.

The only spike that needs a **framebuffer** — S3, S4 and S6 all run with
`-display none` because nothing they prove is visible. So it adds three things
the others have no use for: `virtio-gpu-pci` (a display with no window, whose
default 1280x800 is exactly the 80x25 reference geometry), screendumps over
**QMP**, and keypresses injected over QMP as qcodes to a USB keyboard, so they
travel the real path — HID, the kernel keymap, the VT's XLATE translation — and
arrive as the bytes a person's keypress would produce.

It also boots the kernel and initrd out of the ISO directly rather than through
GRUB, purely so each phase can set its own command line. `palette` needs two
boots and the reason is the finding: one of them masks `setvtrgb.service`.

- [`s1-look/`](s1-look) is the painter — NativeAOT C#. Throwaway like the rest:
  no damage tracking, no screen stack, no error handling. What survives is what
  it *measured* — the key table in `Tui/Keys.cs` is the one the Linux console
  actually produced, and `Native/Termios.cs` records two things Phase 1 would
  otherwise rediscover (read with `read(2)`, and drain the queue first).
- [`s1-look.sh`](s1-look.sh) runs **inside** the live session. Every subcommand
  ends by echoing a marker, because a marker the harness typed is a marker the
  shell will echo back (docs/BUILD-NOTES.md #16).
- [`run-s1.py`](run-s1.py) runs on the **host**: builds the payload, drives the
  console, takes the screendumps and compares them against the font.
- [`../../docs/SESSION-S1-LOOK.md`](../../docs/SESSION-S1-LOOK.md) is the write-up.

The console font is **not** part of the spike — it is a real build stage in
[`../../build/lib/build-console-font.sh`](../../build/lib/build-console-font.sh),
and `./run-s1.py font` just runs it.

## S3

```bash
./run-s3.py probe      # boot the live ISO and prove the console is drivable; writes nothing
./run-s3.py install    # blank disk -> installed ZFS-on-LUKS system
./run-s3.py boot       # boot from that disk ALONE and verify the pass criterion
./run-s3.py all        # both, in order (~25 min on Apple Silicon)
./run-s3.py reset      # discard the VM state
```

Needs `out/os7-arm64.iso` (`make build-arm64`) and `qemu-system-aarch64`.
VM state and full serial logs land in `../../.vm/s3/`, which is gitignored.
The passphrase is `os7spike` and the spike leaves the `os7` account
**passwordless** so the harness can log in — a spike affordance, not a pattern.

- [`s3-zfs-luks.sh`](s3-zfs-luks.sh) runs **inside** the live session and does
  the install. Its comments explain every non-obvious ordering constraint at the
  point where it bites; that is the deliverable.
- [`run-s3.py`](run-s3.py) runs on the **host**: builds a payload ISO, drives
  QEMU's serial console, and checks the result.
- [`../../docs/SESSION-S3-ZFS-LUKS.md`](../../docs/SESSION-S3-ZFS-LUKS.md) is
  what it proved, what it does not prove, and the eight things it depends on.

`s3-zfs-luks.sh` destroys everything on the disk it is given. It refuses the
live medium and a target with mounted partitions, and that is the extent of its
safety.

## S4

```bash
./run-s4.py sb        Secure Boot on, Microsoft keys, no TPM
./run-s4.py enroll    enrol the TPM and rebuild the initramfs
./run-s4.py auto      boot again — must NOT ask for a passphrase
./run-s4.py notpm     boot with no TPM — must ask for one again
./run-s4.py all       all four, in order
./run-s4.py reset     discard S4 state (the S3 disk is left alone)
```

Needs S3 to have run (it boots a **copy** of `.vm/s3/s3-target.qcow2`) and
`brew install swtpm`. Secure Boot firmware is fetched from the `ubuntu:26.04`
container into `../../.vm/firmware/` automatically — Homebrew's QEMU ships none
for aarch64.

**Budget an hour for `all`.** Ubuntu's AAVMF renders GRUB's 30-second countdown
on a 238-column serial console, which takes 10–15 minutes of wall time per boot.
The work itself takes seconds.

- [`s4-tpm-enroll.sh`](s4-tpm-enroll.sh) runs **inside** the installed system:
  `systemd-cryptenroll`, plus the two initramfs pieces that make the LUKS2 token
  actually get used at boot — which is the part nobody tells you about.
- [`run-s4.py`](run-s4.py) drives QEMU with `AAVMF_CODE.secboot.fd` and `swtpm`.
- [`../../docs/SESSION-S4-SECUREBOOT-TPM.md`](../../docs/SESSION-S4-SECUREBOOT-TPM.md)
  is the write-up.

## S2

```bash
./run-s2.sh build [arch]   publish the NativeAOT binary in os7-build:<arch>
./run-s2.sh iso   [arch]   run that binary inside the ISO's own root
./run-s2.sh all   [arch]   both, in order              (default arch: arm64)
```

No VM: `iso` overlays a tmpfs on the read-only squashfs and chroots in, so the
binary meets the image's real glibc and ICU in seconds. It runs the binary
twice — once as the image ships, and once with `/usr/lib/dotnet` deleted from
the overlay, because the ISO **does** carry `dotnet-sdk-10.0` and running there
otherwise proves nothing about runtime independence.

`build amd64` works on an Apple Silicon host even though `make build-amd64` does
not — the `ENOSYS` in BUILD-NOTES #12 is specific to debootstrap's tar. But
`iso amd64` needs an amd64 ISO, which does not exist yet.

- [`s2-nativeaot/`](s2-nativeaot) is the project. Deliberately not a
  hello-world: it exercises `LibraryImport` into libc, source-generated JSON,
  `Process.Start` and German globalization — the four things SETUP-PLAN §6.2
  commits `os7-setup` to and NativeAOT can break.
- [`s2-nativeaot.sh`](s2-nativeaot.sh) runs in the container and installs the
  packages `os7-build` is missing; that list is the deliverable.
- [`../../docs/SESSION-S2-NATIVEAOT.md`](../../docs/SESSION-S2-NATIVEAOT.md)
  is the write-up.

## Shared

The VM harness library lives in [`../testing/`](../testing), not here — the
spikes wrote it first, and `os7-setup`'s own verification now shares it.

- [`../testing/vmconsole.py`](../testing/vmconsole.py) — serial-console driving:
  an expect loop, character-at-a-time typing, and just enough terminal emulation
  to keep PowerShell alive on a line with nothing on the other end
  (docs/BUILD-NOTES.md #16).
- [`../testing/vmscreen.py`](../testing/vmscreen.py) — the framebuffer half:
  QMP screendumps, keypresses injected as qcodes to a USB keyboard, and reading
  the screen back through the console font. S1 needed it first; Phase 1 needs
  exactly the same thing.
