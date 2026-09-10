# Session — Secure Boot: where it already worked, and the one place it did not

Answers the question *how do we get Secure Boot working* by measuring what was
there before changing anything, and then changing it. The short version:
**three of the four links in the chain were already in place, including on
amd64; the missing one was the install medium's bootloader; and since
1.0.0.192 the medium boots under Microsoft-keyed firmware with Secure Boot on.**

> **Result.** `OS7-1.0.0.192-amd64.iso` boots to `os7-setup`'s welcome screen
> under `OVMF_CODE_4M.ms.fd`; the same ISO under the non-Secure-Boot firmware
> produces a **byte-identical** screendump, so one path serves both worlds.
> `check-image.py amd64` went from **13 failures to zero**, and
> `run-secureboot.py all` is **32 ok, 0 failed** on this host: the medium
> boots signed, a machine is installed from it, that machine boots with no
> medium and unlocks itself from the TPM with nothing typed, and the same disk
> under non-enforcing firmware asks for the passphrase again. And
> `Get-OS7SecureBoot` answers the question an administrator actually asks,
> agreeing with `od` on the firmware's own variable (§10).

§1–§6 are what was measured before anything changed, read out of artefacts
with nothing booted. §7 is the medium, §8 the harness's firmware, §9 the
machine, §10 the surface an operator types.

**Dates:** 2026-09-07 (§1–§7) and 2026-09-08 (§8–§10) · **Host:** x64 Windows +
Docker Desktop, KVM through the container · **Method for §1–§6:** no VM at all
— `xorriso` in `os7-vm:amd64` for the ISO, `qemu-img dd` + a GPT parser +
`mtools` in `ubuntu:26.04` for the installed disk's ESP, `sbverify` for every
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
no emulation, because on the day of that measurement this host had none
registered. It does since 2026-09-09 (§"What was NOT measured"), so the same
question could be asked more directly now; the route above is recorded because
it is the route the numbers below came from. It ships
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

## 8. The harness can ask for Secure Boot now

`VmArch(secure_boot=True)` picks the other firmware pair. `vmarch.py` is the
only place that decides it, per its own charter, and the flag is a
**constructor argument rather than an environment variable** on purpose:
whether a run enforced Secure Boot must be visible in the code that started
it, because "was that measured with Secure Boot on?" is a question no
environment answers six months later.

| arch | Secure Boot off (default) | Secure Boot on |
|---|---|---|
| arm64 | `edk2-aarch64-code.fd` + `edk2-*-vars.fd`, Homebrew's QEMU | `AAVMF_CODE.secboot.fd` + `AAVMF_VARS.ms.fd`, fetched from `ubuntu:26.04` into `.vm/firmware/` — the same directory and the same command spike S4 uses, so the two share one download |
| amd64 | `OVMF_CODE_4M.fd` + `OVMF_VARS_4M.fd` | `OVMF_CODE_4M.secboot.fd` + `OVMF_VARS_4M.ms.fd`, both already in `os7-vm:amd64` |

**Secure Boot is a property of the PAIR, and that is why one flag on one object
controls both files.** The enforcing build with a key-less variable store
leaves `SecureBoot` at 0 — no PK, nothing to enforce against — and the
non-enforcing build with the MS-keyed store enforces nothing either. A mode
that got one of the two right would be worse than no mode: the machine boots
and the harness reports Secure Boot. `firmware_code()` and `prepare_vars()`
therefore read the same flag off the same object, so a caller cannot have one
without the other.

On amd64 the code file is *literally the same file* both ways round:
`OVMF_CODE_4M.ms.fd` is a symlink to `OVMF_CODE_4M.secboot.fd` (measured), so
the `.ms` name says nothing about the code and everything about the vars it is
meant to be paired with. vmarch names the enforcing build by what it is.

### The trap this created, and the marker that closes it

`prepare_vars()` keeps an existing variable store, and that is load-bearing:
TPM enrolment lives in it, so a bench's second boot must use what its first
boot wrote. But **the two stores are the same size — 540 672 bytes both — and
differ only in content**, so a Secure Boot run against a bench created before
this change would boot happily with `SecureBoot=0` while the harness reported
having tested Secure Boot. Nothing would fail.

So a new store gets a `<vars>.firmware` marker beside it, and a mismatch is a
`SystemExit` naming the file and the fix. **A missing marker means `plain`** —
the only mode that existed before, and every bench under `.vm/` predates it,
so nothing existing breaks.

### What was measured

* `check-vm-arch.py` went from **41 checks to 71** (arm64 19 → 33, amd64
  22 → 38) and is green. The strongest of the new ones builds a complete
  `vmscreen.Lab` argv both ways and requires that **exactly one argument
  differs** — the firmware code pflash drive. A firmware mode that leaked into
  anything else would fail there.
* Both refusals are exercised without Docker: a plain store offered to a
  Secure Boot run, and a Secure Boot store offered to a plain one.
* The container path was run for real: `prepare_vars(secure_boot=True)`
  produces a file byte-identical to the container's `OVMF_VARS_4M.ms.fd`
  (`d2e3a79d28c1c932…`), the plain mode still produces `OVMF_VARS_4M.fd`
  (`5d2ac383371b4083…`), and both markers are written.
* **And the pair vmarch names discriminates**, driven with the paths
  `VmArch('amd64', secure_boot=True)` returns rather than hand-written ones:
  1.0.0.192 reaches GRUB's menu, 1.0.0.175 answers `Access Denied -- rejected
  probably by Secure Boot`.

### The seam step 4 needs already exists

`vmscreen.Lab` and `os7lab` both take `arch=` and accept a `VmArch` **instance**,
so a Secure Boot harness needs no change in either:

```python
Lab("sbtest", arch=VmArch(secure_boot=True))
```

What is still missing for step 4 is not firmware but a *vehicle*: every
existing harness hands QEMU `-kernel`, so none of them boots the medium's
bootloader (BUILD-NOTES #134). `Lab.qemu_args(cmdline=None)` with
`iso_as_disk=False` is the shape that would.

## 9. The gate: `run-secureboot.py`, and what a machine said

[`installer/testing/run-secureboot.py`](../installer/testing/run-secureboot.py),
four phases, on the x64 Windows host with KVM in the container:

| phase | the claim |
|---|---|
| `medium` | the medium boots through its OWN signed bootloader under Microsoft keys, and the live system says Secure Boot is on |
| `install` | a machine is installed, unattended, FROM that verified medium |
| `disk` | that machine boots with no medium at all and unlocks from the TPM with nothing typed |
| `policy` | the same disk under NON-enforcing firmware **must** ask for the passphrase — and must still accept it |

### The vehicle, which is the part that did not exist

No harness in `installer/testing/` could boot the medium through its
bootloader: they all hand QEMU `-kernel` and `-initrd` lifted out of the ISO
(BUILD-NOTES #134). This one attaches the ISO with `-cdrom` and lets the
firmware find `\EFI\BOOT\BOOTX64.EFI` itself. The medium then has no serial
console — the product's menu puts none on the command line, and should not —
so the harness types at **GRUB's own command line**, which works because
**GRUB reads the serial line under OVMF**: `c` opens a `grub>` prompt and a
typed command is *executed*, not merely echoed (measured 2026-09-08; #16 is
why that distinction was checked rather than assumed). One token of the
resulting command line is the harness's, `console=ttyS0,115200`; the rest is
the medium's own entry.

`-kernel` also boots under Secure Boot, measured the same day — so the
existing harnesses do not have to be rebuilt to run under it.

### What the machine said

`medium`, ten checks, every one of them the guest's own answer rather than the
host's inference:

```
ok  the firmware STARTED the loader on the medium
ok  GRUB drew the product's own menu
ok  the live session booted the medium's entry plus a console
ok  the live system reports SecureBoot enabled — SecureBoot enabled
ok  and the kernel logged Secure Boot enabled — [0.010868] secureboot: Secure boot enabled
ok  the kernel is in lockdown, as Secure Boot makes it — none [integrity] confidentiality
ok  and Canonical's prebuilt zfs.ko still loads under it — lsmod counted 1
ok  and the medium's own loader names Microsoft's UEFI CA — sbverify matched 3
```

**Lockdown is the consequence nobody had asked about.** Secure Boot puts an
Ubuntu kernel into integrity lockdown, after which an unsigned module does not
load — which is what makes the "never zfs-dkms" decision (SETUP-PLAN §5)
load-bearing rather than tidy. The module loads; had it not, an install would
have died at the pool step with no obvious connection to a firmware setting.

`install` finished unattended from that medium, and `disk` then produced the
finding below. `policy`, three checks, is the control — and its evidence is
the initramfs speaking for itself:

```
OS/7 TPM: the TPM would not unlock os7_root - the passphrase still works
OS/7 TPM: nothing was unlocked from the TPM
Please unlock disk os7_root: TPM policy does not match current system state.
Either system has been tempered with or policy out-of-date
```

and the passphrase still opens it, which is the half U8 is about. The control
is also stronger than "disabled": `mokutil` on `OVMF_CODE_4M.fd` answers **"This
system doesn't support Secure Boot"**, because that build has no Secure Boot
support compiled in at all rather than merely shipping no keys. Which is a
second argument for vmarch pairing a code build with its variable store: the
enforcing build with a key-less store would have answered "disabled" and
enforced nothing.

`run-secureboot.py all`, from a blank disk, is **32 ok, 0 failed** — and since 1.0.0.193 four of those are `Get-OS7SecureBoot` out of the .deb, on the live medium and on the installed machine, required to agree with `mokutil` on the same machine (§10).

### The finding: #100's cause was the harness's own boot

**A machine installed from a Secure-Boot-on medium unlocked from the TPM on
its FIRST boot.** No re-enrolment, nothing typed — twice, in two independent
runs.

That contradicts the plain reading of BUILD-NOTES #100 — "the install-time TPM
seal does not open through shim" — and the explanation is the vehicle. PCR 7
measures the Secure Boot policy *and the certificate shim used to validate
what it loaded*. The live session's shim validates `gcdx64.efi`, the installed
machine's shim validates `grubx64.efi`, both against the same Canonical
certificate: PCR 7 agrees. The binaries differ and land in PCR 4, which
`--tpm2-pcrs=7` does not seal to. Under `-kernel`, shim never runs at all —
and that was the different measurement #100 saw.

**UL1 keeps its job**: a shim or `dbx` update after the install moves PCR 7 for
real, which is what `policy` measures. What changes is the routine case — a
machine installed from a Secure-Boot-on medium onto Secure-Boot-on firmware
needs no re-enrolment, and the harnesses that said otherwise were reporting
their own `-kernel` boot. #100 carries the correction.

### Three firmware variable stores, and the one that cost a run

Booting through the firmware makes its NVRAM matter, which is new here.
`grub-install` writes an `OS7` boot entry during the install and it lands in
the variable store — so a `medium` run after an install has firmware that
prefers the DISK, and `-boot d` does not overrule it because OVMF honours its
own BootOrder. The first `all` run sat at a passphrase prompt for a machine
the phase was not about, and said so in the guest's words:

```
OS/7 TPM: no /dev/tpmrm0 - falling back to the passphrase
Please unlock disk os7_root:
```

So `medium` gets its own store, made fresh, and attaches **no disk**;
`install` starts from a fresh store because a blank disk is a new machine, and
what the install writes into it is what `disk` then boots from; `policy` has a
third, non-enforcing one. Every other harness is immune to all of this, because
`-kernel` never asks the firmware what to boot.

### What is reused, and how that is kept honest

The install sequence, the plan, the one-boot-of-the-disk machinery and the
trick that gives an installed amd64 machine a serial console at all (#132) are
`run-s5.py`'s, reached by **repointing run-s5's module-level `lab`** at this
harness's Secure Boot one. That is a loud thing to do, so `patch_s5()` asks
run-s5 what firmware it would now use and refuses to continue unless the
answer is the enforcing build and this harness's disk. An un-repointed global
would otherwise run the whole file on Secure-Boot-off firmware and report a
Secure Boot result.

Using run-s5's plan is deliberate rather than lazy: same hostname, same
account, same passphrase, so the machine this harness installs IS the machine
run-s5 installs and the two runs are comparable.

### What this harness does NOT measure

* **The re-enrolment branch of `disk` never ran**, because the first boot
  unlocked. It is kept for the case #100 describes and is therefore unexercised
  code in this file.
* **arm64, entirely.** No arm64 ISO has been built with the new
  `efi-remaster.sh`, `vmarch.ensure_firmware()` has never downloaded the
  Secure Boot AAVMF, and this host cannot run either.
* **Real hardware.** swtpm is a software TPM and OVMF is not a vendor's
  firmware. What generalises is the reasoning about PCR 7; what does not is any
  claim about a particular machine's db, dbx or NVRAM behaviour.

## 10. The surface an operator types

Everything above is the build and the harness. The gap this leaves is the one
an administrator actually meets: on 2026-09-08 there was no way to ask an OS/7
machine about Secure Boot in PowerShell. The Windows admin this product is for
types `Confirm-SecureBootUEFI`.

`Get-OS7SecureBoot` (`powershell/OS7/OS7.SecureBoot.ps1`) answers it, and it
**reads the UEFI variable's data byte rather than parsing `mokutil`** — because
mokutil's answer is not one sentence but several, and which one you get depends
on the firmware rather than on the setting. Measured under the two OVMF builds
this repository tests with:

| firmware | `mokutil --sb-state` |
|---|---|
| `OVMF_CODE_4M.secboot.fd` + `OVMF_VARS_4M.ms.fd` | `SecureBoot enabled` |
| `OVMF_CODE_4M.fd` + `OVMF_VARS_4M.fd` | `This system doesn't support Secure Boot` |

The second is **not** "disabled". That build has no Secure Boot support
compiled in, so the variable is absent — a third state, and one an operator
needs told apart from "off", because "off" can be switched on in a firmware
setup screen and "absent" cannot. So the cmdlet gives three outcomes per
answer, the rule `Get-OS7TimeSynchronization` already follows:

```
Supported = $null    not a UEFI machine — the question does not apply
Supported = $false   UEFI, and this firmware has no Secure Boot at all
Supported = $true    the firmware has it
Enabled   = $null    could not be asked
Enabled   = $false   asked, not enforcing
Enabled   = $true    asked, enforcing
```

and it reports **`Lockdown`** beside them, because that is the consequence an
operator collides with rather than the setting they set: Secure Boot puts an
Ubuntu kernel into integrity lockdown, after which an unsigned module does not
load. Which is what makes "never zfs-dkms" (SETUP-PLAN §5) load-bearing.

There is deliberately no `powershell/Firmware/` layer beneath it: what the
product needs today is two sysfs reads, and P2's own argument for a generic
layer is a surface worth reusing. Enrolling keys, reading `dbx` or driving MOK
would be that surface, and the moment to extract one.

### Two rules that carry real defects, and both were planted

`installer/testing/check-secureboot-logic.py` — 19 checks, no VM, seconds,
against fake roots, and green on both Windows and Linux (the image's own pwsh
7.6.5). Two of its cases exist because the implementation could plausibly be
written the other way:

* **An efivarfs file is four bytes of attributes and then the data.** Byte 0
  is the low byte of the attribute word, which for an ordinary NV+BS+RT
  variable is `0x07` — truthy for every variable in the store, including a
  SecureBoot of 0. The fixture writes `07 00 00 00 00` and requires `$false`.
  Planted (`$bytes[0]` instead of `$bytes[4]`): **RED**, with
  `Enabled=True (byte 0 is 0x07 and truthy)`.
* **`/sys/kernel/security/lockdown` lists every mode and brackets the live
  one:** `none [integrity] confidentiality`. The first word is `none` on a
  locked-down machine. Planted (first word instead of bracketed): **RED**,
  reporting `'none'` for a machine in integrity lockdown — the answer an
  operator wants least, in the case where it matters most.

`OS7_SB_MODULE` points the check at another copy of the module, which is how
both of those were proven to fire. Same idea as `check-ps-traps.py`'s
`OS7_SCAN_ROOT`.

And the cmdlet's first run found a third defect in itself, which is why the
repo has `check-ps-traps.py`: `return @()` from a PowerShell function returns
**nothing**, so `$bytes` was `$null` and `$null.Count` threw — BUILD-NOTES
#112/#119, on the exact path the function exists to report (the variable is
absent). `@()` around the call site is the fix and it is named in the code.

### And the machine corrected the code's comment

The cmdlet's decision table is fake roots; the one thing fake roots cannot
check is what a firmware actually writes. So `OS7.SecureBoot.ps1` was pushed
into the installed Secure Boot machine — base64, and its `sha256sum` on the
machine compared against the repository's, so what ran was the file byte for
byte — dot-sourced, and its answer held against `od` on the variable itself:

```
the firmware wrote: 06 00 00 00 01
the cmdlet said:    Firmware=UEFI Supported=True Enabled=True SetupMode=False
                    Lockdown=integrity Reason=
```

Two independent readings of one fact, and the cmdlet is right. **And the
attribute word is 06, not 07.** The code's comment said "which for a NV+BS+RT
variable is 7", written from the UEFI convention rather than from a machine:
SecureBoot is volatile and firmware-owned, so NON_VOLATILE is clear and the
word is `BOOTSERVICE_ACCESS|RUNTIME_ACCESS`. Both are truthy, so the trap the
comment warns about is unchanged — but the fixture now writes what a machine
writes, and carries a second case with `07` so an implementation reading byte 0
fails on both. That is the whole "measure, do not assert" rule catching this
session's own prose.

The push itself found BUILD-NOTES **#139**: `send_script()` types one
`printf '%s
' '<line>'` per line, and this file is indented with TABS — which
readline on the guest's interactive bash reads as filename completion. The
first attempt produced a file with directory listings inside it and a `wc -l`
that looked plausible.

### The list nobody was checking

Adding one file to the module meant editing it into **four** places by hand:
the `foreach` in `OS7.psm1`, hook 0060's required-file list, the .deb's
required-path list, and the manifest's exports. `build-os7-packages.sh` says
of its own list:

> The two lists are asserted equal by nothing; they are just short enough to
> read side by side

— written by the merge that had already lost four files that way. So
`installer/testing/check-module-parts.py` now asserts it: the four lists name
exactly the 18 parts on disk, every exported name is defined somewhere, and
**the counts in POWERSHELL-REFERENCE.md match what the modules report**. Both
directions proven by planting: a part removed from hook 0060 → RED naming it;
an exported name nothing defines → RED naming it; the reference's old headline
→ RED.

That last rule was red the moment it was written. POWERSHELL-REFERENCE.md said
**202 functions in six modules** and the modules reported **221** — Systemd
had grown two and OS7 sixteen in commits that had nothing to do with the file.
CLAUDE.md makes this exact argument about itself ("a count in prose has nothing
checking it"); now the prose has something checking it.

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
* ~~**arm64: the code path is measured, the medium is not.**~~ **The medium is
  measured too, since 2026-09-09** — `OS7-1.0.0.194-arm64.iso` was built on
  the x64 Windows host under emulation and `check-image.py arm64` passes on
  it: `BOOTAA64.EFI` is Microsoft-signed shim, `grubaa64.efi` beside it is
  `gcdaa64` (prefix `/boot/grub`, hash `cfc15dd8e3794369…` on both sides of
  the medium), `mmaa64.efi` is there, the `$cmdpath` stub is there, and the
  kernel is Canonical-signed. **#12/#23 has no mirror image** (BUILD-NOTES
  #140): amd64 cannot be built on Apple Silicon, and arm64 CAN be built on
  x86_64 — emulated, about an hour and a half against five minutes native,
  after registering the binfmt handler Docker Desktop was missing.

  So what arm64 still owes is exactly one thing: a **BOOT**.
  `run-secureboot.py all` needs HVF and therefore the Mac. The paragraph below
  was written before that, when `out/os7-arm64.iso` was still 1.0.0.175 and
  the code was the open question. What changed first, on 2026-09-08, is that
  arm64 containers run here at all —
  `docker run --privileged tonistiigi/binfmt --install arm64` registered the
  handler that was missing, and `docker run --platform linux/arm64` had been
  answering `exec format error`. With that, the `aa64` branch of
  `efi-remaster.sh` was run against the REAL arm64 squashfs:

  ```
  >>> arm64 EFI: shim=shimaa64.efi.signed.latest (987440 B), grub=gcdaa64 (2533256 B)
  --- resolved: /usr/lib/shim/shimaa64.efi.signed.latest
  ```

  — all three files found, the alternatives symlink chain walked inside the
  extracted tree, exit 0. So the file names and the resolution are right on
  arm64, measured rather than substituted.

  Both of those turned out to be doable here, which is what the paragraph
  above records. Note the inversion the remainder creates: Secure Boot on a
  machine is the first thing in this repository measured on amd64 and
  unmeasured on arm64.
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

**All four steps are done** — the rule (`check-image.py`), the medium
(`efi-remaster.sh`, §7), the firmware mode (`vmarch.py`, §8) and the gate
(`run-secureboot.py`, §9). Secure Boot works on amd64, from the medium through
to a machine that unlocks itself, and every claim above is a measurement.

What it leaves open:

* **arm64 is untouched by all of it.** One `make build-arm64`, one
  `check-image.py arm64`, and one `run-secureboot.py all` on a Mac — the file
  names are the only difference in the code.
* ~~**`Get-OS7SecureBoot` does not exist.**~~ It does since 2026-09-08 (§10).
  What is still owed on that surface is the INSTALLER: the Complete screen
  says nothing about Secure Boot, which is the one place Setup could tell an
  operator that the machine it just built is not protected the way they
  assume. Left as a deliberate decision rather than done in passing, because
  a Complete screen that reports a firmware setting has to say what an
  operator should DO about it, and that text is a product decision.
* **U8 is now demonstrable rather than theoretical**, which makes it more
  urgent, not less: `run-secureboot.py policy` shows the exact prompt a fleet
  meets the morning after a shim or `dbx` update, and nothing escrows the
  passphrase that answers it.
* **#100 needs a decision, not just a correction.** If the routine case needs
  no re-enrolment, UL1's firstboot migration is a belt for the policy-change
  case only — worth saying explicitly in
  [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) rather than leaving
  two mechanisms whose division of labour is implicit.

Two things this session did not touch and that belong to the product rather than
the build: there is **no `Get-OS7SecureBoot`** — an administrator coming from
Windows expects the equivalent of `Confirm-SecureBootUEFI`, and today would have
to type `mokutil` — and **U8 gets more urgent, not less**: with Secure Boot on,
a shim or `dbx` update moves PCR 7, and [S6](SESSION-S6-UPDATE-CYCLE.md)
measured that the passphrase prompt comes back when it does.
