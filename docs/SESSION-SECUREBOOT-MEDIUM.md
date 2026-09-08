# Session — Secure Boot: where it already worked, and the one place it did not

Answers the question *how do we get Secure Boot working* by measuring what was
there before changing anything, and then changing it. The short version:
**three of the four links in the chain were already in place, including on
amd64; the missing one was the install medium's bootloader; and since
1.0.0.192 the medium boots under Microsoft-keyed firmware with Secure Boot on.**

> **Result, 2026-09-07.** `OS7-1.0.0.192-amd64.iso` boots to `os7-setup`'s
> welcome screen under `OVMF_CODE_4M.ms.fd`. The same ISO under the
> non-Secure-Boot firmware produces a **byte-identical** screendump, so one
> path serves both worlds. `check-image.py amd64` went from **13 failures to
> zero**. §7 has the measurements.

§1–§6 are what was measured before the change and were read out of artefacts
with nothing booted; §7 is the change and the boots.

**Date:** 2026-09-07 · **Host:** x64 Windows + Docker Desktop · **Method:** no
VM at all. `xorriso` in `os7-vm:amd64` for the ISO, `qemu-img dd` + a GPT parser
+ `mtools` in `ubuntu:26.04` for the installed disk's ESP, `sbverify` for every
signature, and `dpkg-deb -x` over the arm64 `.deb`s from `ports.ubuntu.com` for
the architecture nothing on this host can execute.

- The check this produced: [`installer/testing/check-image.py`](../installer/testing/check-image.py) — `secureboot_checks()`
- Its recorded correct medium: [`installer/testing/fixtures/secureboot-good.probe`](../installer/testing/fixtures/secureboot-good.probe)

```bash
./installer/testing/check-image.py amd64        # 13 FAIL on 1.0.0.175, listed below
./installer/testing/check-image.py --self-test  # 16 ok, no ISO, no Docker, ~1s
```

## Verdict

| Link | State | How it was measured |
|---|---|---|
| firmware → **shim** on the installed disk | **there**, Microsoft UEFI CA 2011 | the ESP of an `os7-setup` install, read without booting it |
| shim → **GRUB** on the installed disk | **there**, Canonical Master CA | same |
| GRUB → **kernel** | **there**, Canonical Master CA, on the disk *and on the medium* | `sbverify` on `/casper/vmlinuz-7.0.0-30-generic` |
| firmware → **loader on the MEDIUM** | **missing** — 6 828 032 bytes of unsigned `grub-mkstandalone` | `sbverify`: *No signature table present* |

So the answer to "how do we get Secure Boot working" is not a chain to build. It
is one file to stop generating and four to copy — and a rule that says so, which
now exists.

## 1. The installed disk already carries the whole chain, on amd64

Read out of `.vm/manual/target.qcow2` — an `os7-setup` install of 1.0.0.175 from
2026-09-03 — with no boot: `qemu-img dd … count=700` for the head of the disk,
the GPT parsed in Python (`os7-esp` at offset 1 048 576, 512 MiB; then
`os7-bpool`, then `os7-luks`), and the ESP itself read with `mtools` at
`@@1048576`.

| ESP path | bytes | what it is | image signature issuer |
|---|---|---|---|
| `/EFI/BOOT/BOOTX64.EFI` | 966 768 | `shimx64.efi.signed` | **Microsoft Corporation UEFI CA 2011** |
| `/EFI/BOOT/grubx64.efi` | 2 398 088 | **`gcdx64`**`.efi.signed` | Canonical Ltd. Master Certificate Authority |
| `/EFI/BOOT/mmx64.efi` | 856 280 | MokManager | Canonical |
| `/EFI/BOOT/grub.cfg` | 125 | the boot-environment prefix | — |
| `/EFI/OS7/shimx64.efi` | 966 768 | the NVRAM path's shim | Microsoft |
| `/EFI/OS7/grubx64.efi` | 2 828 168 | `grubx64.efi.signed` | Canonical |

The shim on that disk is **byte-identical** to `/usr/lib/shim/shimx64.efi.signed`
in the image it was installed from (`4c89145e958cf592…`), and the removable
loader is byte-identical to that image's `gcdx64.efi.signed` (`dc505a15c1bd9787…`).

This is the first amd64 Secure Boot evidence in the repository. [S4](SESSION-S4-SECUREBOOT-TPM.md)
proved the chain on arm64, on a disk the **S3 spike** had installed; that it
also holds for a disk `os7-setup` installed, on the other architecture, had
never been asked.

## 2. `grub-install` writes the chain even from a medium that booted with Secure Boot OFF

Worth naming because it is not obvious and because it is what makes §1 possible.
Every install this repository has ever performed booted its medium either with
`-kernel` (`vmscreen.py`, so no bootloader ran at all) or under
`OVMF_CODE_4M.fd`, the non-Secure-Boot firmware `vmarch.py:220` picks
*deliberately* — because the medium's GRUB is unsigned and the MS-keyed build
would refuse it. The Secure Boot chain landed on the disk regardless.

`strings /usr/sbin/grub-install` shows it knows all three names —
`/usr/lib/shim/shim%s.efi.signed`, `grub%s.efi.signed` and `gcd%s.efi.signed` —
and that the flag is `--no-uefi-secure-boot`, i.e. an opt-*out*.

## 3. `gcd` and `grub` differ in one thing, and it decides whether a medium boots

Measured with `strings` on the two signed images shipped in the product:

| file | prefix compiled into it |
|---|---|
| `grubx64.efi.signed` / `grubaa64.efi.signed` | `/EFI/ubuntu` |
| `gcdx64.efi.signed` / `gcdaa64.efi.signed` | `/boot/grub` |

`/EFI/ubuntu` is a directory no OS/7 medium has. A medium built with the disk
image is correctly signed, chains correctly from shim, and lands at a GRUB
prompt — which is why the check reports the two cases separately.

And the 125-byte `grub.cfg` beside each loader in §1 is the mechanism that
resolves this: Ubuntu's GRUB reads the configuration **next to the binary it was
loaded from**. That is not folklore here — it is the file that names which boot
environment's menu is read ([SESSION-BOOT-ENVIRONMENTS.md](SESSION-BOOT-ENVIRONMENTS.md)),
so the product already depends on it working.

## 4. The medium: one unsigned file, on both of its sides

`out/OS7-1.0.0.175-amd64.iso`, read with `xorriso`:

```
El Torito images   :   N  Pltf  B   Emul  Ld_seg  Hdpt  Ldsiz         LBA
El Torito boot img :   1  UEFI  y   none  0x0000  0x00  49152          41
El Torito img path :   1  /boot/grub/efiboot.img

/EFI/BOOT/BOOTX64.EFI    6828032    sbverify: No signature table present
```

The same unsigned file is inside `boot/grub/efiboot.img` (25 165 824 bytes, the
only El Torito entry, UEFI platform). There is no `shim`, no `grubx64.efi`, no
`mmx64.efi` and no `grub.cfg` beside the loader. `build/lib/efi-remaster.sh`
says all of this in its own header and calls it an open item.

## 5. Nothing has to be added to the product, and arm64 is symmetric

Out of the **shipped** package manifests, both architectures:

```
shim-signed            1.59+15.8-0ubuntu2
grub-efi-<arch>-signed 1.215+2.14-2ubuntu1
sbsigntool             0.9.4-3.1ubuntu9
mokutil                0.7.2-2
```

`sbsigntool` being in the product is what lets the new check verify signatures
with **the image's own** `sbverify` rather than a tool the build container
happens to carry.

arm64 was measured by unpacking `shim-signed:arm64` and
`grub-efi-arm64-signed:arm64` from `ports.ubuntu.com` inside an **amd64**
container (`dpkg --add-architecture arm64`, `apt-get download`, `dpkg-deb -x`) —
no emulation, because this host has none registered. It ships
`shimaa64.efi.signed.latest`, `mmaa64.efi`, `BOOTAA64.CSV`, and
`gcdaa64.efi.signed` with prefix `/boot/grub`. The plan is the same file names
with `aa64` and `arm64` substituted, which is how the check is parameterised.

## 6. This host can boot Secure Boot today

`os7-vm:amd64` carries, from the `ovmf` package:

```
OVMF_CODE_4M.ms.fd -> OVMF_CODE_4M.secboot.fd
OVMF_VARS_4M.ms.fd
```

So the gate that boots a signed medium under Microsoft keys needs no new
dependency — only a firmware choice in `vmarch.py`, which is the one place that
is allowed to make it.

## What the check now does, and why it is two halves

`secureboot_checks()` reads both sides of the medium — the ISO9660 tree and the
FAT image El Torito actually points at, because firmware picks one and different
firmware picks differently — and asks six questions per side plus three global
ones. On 1.0.0.175 it produces **13 failures**:

```
ok    the image ships the signed loaders the medium is assembled from — shim 966768B, gcd 2398088B, grub 2828168B
FAIL  the ISO9660 tree's BOOTX64.EFI is shim, signed by Microsoft's UEFI CA — No signature table present
FAIL  and it is the shim THIS image ships, byte for byte — medium f974762b95ee99b7 vs image 4c89145e958cf592
FAIL  and grubx64.efi beside it is GRUB, signed by Canonical — <not on the medium>
FAIL  and it is the CD-media build (gcd), whose prefix is /boot/grub — medium <absent> vs gcd dc505a15c1bd9787
FAIL  and MokManager (mmx64.efi) is beside it, so a refusal has somewhere to go — absent
FAIL  and a grub.cfg sits beside the loader, where that GRUB looks for it — absent
      … the same six for the El Torito FAT image …
ok    both sides of the medium carry the same loader — iso f974762b95ee vs esp f974762b95ee
ok    the kernel the medium boots is signed by Canonical
FAIL  the medium's menu loads no GRUB module from disk (a signed GRUB will not) — insmod all_video
note  the El Torito image carries no /boot/grub/grub.cfg, the stub gcd's compiled-in prefix would resolve to
```

Three of those lines are **ok on the ISO that fails everything else**, and that
is deliberate: a block of checks that is uniformly red says nothing about which
of them would have caught a regression. The `insmod` line is a real finding —
under Secure Boot the signed GRUB refuses to load a module from disk, so a menu
that calls `insmod` works on the Secure-Boot-off bench the medium was developed
on and nowhere else.

**And the green path was proven separately, because on this artefact it cannot
be.** A rule every ISO fails is a rule that might be *unsatisfiable*, and the
next session would read that as step 2 having failed. So `secureboot_checks()`
is a function rather than a block, and `--self-test` hands it the readings from
a medium that is assembled correctly — the installed ESP of §1, hashed and
verified by the same probe script — and requires all 16 to pass. Same discipline
as `check-ps-traps.py`'s `OS7_SCAN_ROOT`: a rule is worth having once it has
been shown both to fire and to stay quiet.

The fixture's one invented section is the menu, written the way
`efi-remaster.sh` will write it once it stops calling `insmod` — so that rule
cannot be satisfied by deleting the rule.

## 7. The change, and the boot that settles it

`build/lib/efi-remaster.sh` no longer calls `grub-mkstandalone`. It takes four
things out of the squashfs the same build just wrote — not out of the build
container, so the pin in `build/config/os7-release.conf` governs the medium's
loader exactly as it governs the installed machine's — and puts them on **both**
sides of the medium:

| on the medium | out of the image |
|---|---|
| `/EFI/BOOT/BOOTX64.EFI` | `/usr/lib/shim/shimx64.efi.signed` (resolved) |
| `/EFI/BOOT/grubx64.efi` | `/usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed` |
| `/EFI/BOOT/mmx64.efi` | `/usr/lib/shim/mmx64.efi` |
| `/EFI/BOOT/grub.cfg` | a three-line stub: find `/.disk/info`, set the prefix, `configfile` |

and `insmod all_video` is gone from the menu, because a signed GRUB will not
load a module from disk and the medium's own development bench had Secure Boot
off.

Two traps were designed around and then **measured** rather than argued:

* **`readlink -f` is unusable here.** On the extracted tree it returns
  `/etc/alternatives/shimx64.efi.signed` and **exit 0** for a file that does
  not exist — and would return a *real* file, the container's own shim, if the
  build image ever installed `shim-signed`. BUILD-NOTES **#133**. The script
  walks the symlink chain inside the extraction root instead, which is the
  resolution `grub-install` performs inside the installed system.
* **`unsquashfs` exits 0 having extracted nothing.** Its exit code is discarded
  on purpose and each of the three files is required by name. Proved by
  planting a defect (`GRUB_TARGET=nosucharch`):
  `!!! the image carries no signed boot chain for amd64: /usr/lib/grub/nosucharch-efi-signed/gcdx64.efi.signed`, exit 1.

### The boots

**Nothing in `installer/testing/` can boot the medium through its own
bootloader** — every harness hands QEMU `-kernel`, which is exactly why an
unsigned loader survived on the medium for months (BUILD-NOTES **#134**). So
these four boots were one-off QEMU runs in `os7-vm:amd64` with `--device
/dev/kvm`, `-cdrom … -boot d`, and the firmware pair named below. Harnessing it
is step 3.

| medium | firmware | result |
|---|---|---|
| 1.0.0.175 (old) | `OVMF_CODE_4M.fd` | GRUB 2.14 draws the three OS/7 entries, counts down, boots |
| 1.0.0.175 (old) | `OVMF_CODE_4M.ms.fd` | `Access Denied -- rejected probably by Secure Boot`, then `>>Start PXE over IPv4.` |
| **1.0.0.192 (new)** | `OVMF_CODE_4M.ms.fd` | `BdsDxe: starting Boot0002`, GRUB 2.14, the menu, and at 100 s **Setup's welcome screen** |
| 1.0.0.192 (new) | `OVMF_CODE_4M.fd` | the same screen, **byte-identical PNG** (`b4c0d371ba7f3dc76840…`) |

The old medium's failure is in the firmware's own words, which is the kind of
diagnostic worth quoting: it did not merely fail to boot, it fell through to
PXE.

**And a finding that makes step 4 cheaper: OVMF and GRUB both write to the
serial line on amd64.** The entire boot menu is legible as text — no
screendump needed until the kernel takes the console. A harness for this can
assert on strings.

### What the medium no longer needs

`check-image.py`'s note reports that the El Torito FAT image carries **no**
`/boot/grub/grub.cfg` — the stub `gcd`'s compiled-in prefix would resolve to.
It was written as a belt in case `$cmdpath` did not apply on El Torito the way
it does on the installed ESP. **It is not needed**: 1.0.0.192 has no such stub
and boots. That is why the line stayed a note and never became a check.

### The fixture is now a recording of a real medium

`--self-test`'s fixture was first taken from the installed ESP, because on the
day the rule was written no medium satisfied it. It is now re-recorded from
`OS7-1.0.0.192-amd64.iso` by `check-image.py --record-secureboot amd64` — a
verb rather than a shell recipe, for the reason `run-zfs.py` has `capture`: a
fixture is worth what its provenance is worth.

## A weak diagnostic, named as such

`strings`-probing `gcdx64.efi.signed` for built-in module names answered
`iso9660 YES`, `search_fs_file YES`, `linux YES`, `gfxterm YES`, `configfile YES`,
`squash4 YES` — and `fat no`, `all_video no`. `fat` **must** be built in, or
GRUB could not read the ESP it was loaded from, so the probe is unreliable and
only a boot decides. It is enough to justify dropping `insmod all_video` from
the menu and not enough to conclude anything else. Recorded here so nobody
mistakes it for a measurement.

## What was NOT measured

* **Nothing was booted.** Not one claim in this document is a boot result.
* **arm64 is unrun, and its medium is still the unsigned one.**
  `out/os7-arm64.iso` is 1.0.0.175, built before any of this; no arm64 ISO has
  been built with the new `efi-remaster.sh`, so the `aa64` branch of both the
  build and the check has never executed. `docker run --platform linux/arm64
  ubuntu:26.04` on this host answers `exec format error` — no binfmt handler is
  registered — so `check-image.py arm64` cannot run here either. The `.deb`
  measurements in §5 are file listings, not a run. **What arm64 owes is one
  `make build-arm64` followed by `check-image.py arm64`**, and the file names
  are the only thing that differs.
* ~~**Whether a medium assembled this way boots.**~~ Measured in §7: it does,
  under Microsoft keys. What is still unmeasured is everything AFTER the
  welcome screen — no install has been performed from a Secure-Boot-on medium,
  so nothing is known about `mokutil --sb-state` inside the live session, about
  kernel **lockdown** (Secure Boot enables it in integrity mode, and an
  unsigned module then does not load — Canonical's prebuilt `zfs.ko` is signed,
  which is exactly why "never zfs-dkms" matters), or about a machine installed
  that way. That is step 4.
* **#93 applies to `os7img:175`** and was checked rather than assumed: the
  container was used for file listings and hashes, and `check-image.py` reads
  the same shim and `gcd` out of the **shipped squashfs** — both return
  `4c89145e958cf592…` and `dc505a15c1bd9787…`. The two agree, so nothing here
  rests on the container alone.
* **PCR 7.** Every machine this repository has produced is sealed against a
  Secure-Boot-**off** PCR 7, because every medium booted that way. Once media
  boot signed, installs will seal against the policy production actually has —
  which is a change for the better and the first time it will have been true.

## What it changes in the plan

**Steps 1 and 2 of four are done** — the rule (`check-image.py`, §"What the
check now does") and the medium (`efi-remaster.sh`, §7). The remaining two, in
order:

3. **`installer/testing/vmarch.py`**: a Secure Boot firmware mode — `.ms.fd` on
   amd64, `AAVMF_CODE.secboot.fd` + `AAVMF_VARS.ms.fd` fetched the way
   `run-s4.py` already fetches them on arm64. As an *additional* path, so the
   default command lines stay byte-identical and `check-vm-arch.py` stays green;
   that file gets a property test for the new one.
4. **`installer/testing/run-secureboot.py`**: boot the medium through its own
   bootloader under MS keys and ask the machine (`mokutil --sb-state`, plus
   `dmesg | grep lockdown` and `lsmod | grep zfs`, because Secure Boot turns on
   kernel lockdown and an unsigned module then does not load); install from it;
   boot the installed disk with no medium; then the same with a TPM.

Two things this session did not touch and that belong to the product rather than
the build: there is **no `Get-OS7SecureBoot`** — an administrator coming from
Windows expects the equivalent of `Confirm-SecureBootUEFI`, and today would have
to type `mokutil` — and **U8 gets more urgent, not less**: with Secure Boot on,
a shim or `dbx` update moves PCR 7, and [S6](SESSION-S6-UPDATE-CYCLE.md)
measured that the passphrase prompt comes back when it does.
