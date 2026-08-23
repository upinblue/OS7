# Session S4 — Secure Boot, and TPM2 auto-unlock

Answers `installer/SETUP-PLAN.md` **§10 Phase 0 spike S4**: *does it survive
Secure Boot, and does TPM2 unlock work?* It takes the system
[S3](SESSION-S3-ZFS-LUKS.md) installed and changes only the firmware and the
presence of a TPM.

**Date:** 2026-08-23 · **Method:** the S3-installed disk (a copy of it), booted
in QEMU/arm64 under Ubuntu's `AAVMF_CODE.secboot.fd` with `AAVMF_VARS.ms.fd` —
the Microsoft KEK/db already enrolled — and a `swtpm` software TPM 2.0.

- The enrolment sequence: [`installer/spikes/s4-tpm-enroll.sh`](../installer/spikes/s4-tpm-enroll.sh)
- The harness: [`installer/spikes/run-s4.py`](../installer/spikes/run-s4.py)

```bash
./installer/spikes/run-s4.py all
```

## Verdict

| Phase | Question | Result |
|---|---|---|
| `sb` | Does the S3 system boot with Secure Boot **on**? | **Yes.** `mokutil --sb-state` → `SecureBoot enabled`. |
| `enroll` | Does `systemd-cryptenroll --tpm2-device=auto` work? | **Yes** — sealed to PCR 7, keyslot 1, `systemd-tpm2` token. The passphrase keyslot is kept. |
| `auto` | Does the next boot skip the passphrase? | **Yes** — but **not** without adding two pieces to the initramfs (below). |
| `notpm` | Does a TPM-less machine still boot? | **Yes** — the passphrase prompt comes straight back. |
| **S4** | | **PASS** on arm64. |

What came back from the machine:

```
$ mokutil --sb-state
SecureBoot enabled

$ sbverify --list /boot/efi/EFI/BOOT/BOOTAA64.EFI
image signature issuers:
 - /C=US/ST=Washington/L=Redmond/O=Microsoft Corporation/CN=Microsoft Corporation UEFI CA 2011

$ findmnt -no SOURCE,FSTYPE /
rpool/ROOT/os7_2026.08.1_202608230935 zfs
```

and on the TPM boot, from the initramfs itself:

```
Begin: Running /scripts/local-top ... os7-tpm2: unlocked os7_root from the TPM
…
os7 login:
```

with no passphrase prompt anywhere in between. Remove the TPM and the same disk
prints `Please unlock disk os7_root:` again.

**This settles D1 on the platform it was decided for.** `shim-signed` chains to
Canonical's signed GRUB, the firmware accepts it against the Microsoft UEFI CA,
and ZFS-on-LUKS root comes up underneath — the exact chain §5 chose over
ZFSBootMenu.

## The finding: `cryptsetup-initramfs` does not know what a token is

`systemd-cryptenroll` succeeds on this image and writes a perfectly good LUKS2
token. **On its own it changes nothing at boot**, and it fails silently — you
get the passphrase prompt exactly as before, with no error to explain it.

Two independent reasons:

1. The stock `cryptsetup-initramfs` hook copies `cryptsetup`, `dmsetup`,
   `askpass` and `sed`. It copies **no token handler**, so
   `/usr/lib/*/cryptsetup/libcryptsetup-token-systemd-tpm2.so` is simply absent
   from the initramfs. `grep -i tpm2` over the hook and its boot script returns
   nothing at all.
2. `local-top/cryptroot` feeds a passphrase to `cryptsetup open` on stdin, and
   supplying key material is precisely what makes cryptsetup skip token
   activation.

So the gap is closed with two small pieces, both written by
`s4-tpm-enroll.sh` and both intended for `os7-setup` to write at install time:

**A hook** (`/etc/initramfs-tools/hooks/os7-tpm2`) that carries the token
handler and the libraries it needs.

**A `local-top` script** (`00os7tpm2`) that runs *before* `cryptroot` and tries

```sh
cryptsetup open --token-only -- "$dev" "$name"
```

for every entry in `/cryptroot/crypttab`. If it works, `cryptroot` finds the
mapping already present and returns without asking. If it does not —
no TPM, wrong PCRs, TPM says no — `--token-only` never falls back to a
passphrase itself, so the stock prompt appears exactly as it always did.
**That is the TPM-less recovery path, and it is a property of the flag, not an
afterthought.**

### The name `00os7tpm2` is load-bearing

`initramfs-tools` orders `local-top` with `get_prereq_pairs | tsort`, which for
scripts declaring no prereqs falls back to the directory glob — alphabetical.
The leading `00` is what puts it ahead of `cryptroot`. The script checks the
generated `ORDER` rather than trusting that:

```
/scripts/local-top/00os7tpm2 "$@"
/scripts/local-top/cryptopensc "$@"
/scripts/local-top/zfs "$@"
/scripts/local-top/cryptroot "$@"
```

Note `cryptroot` is last, not third — `tsort` is not pure alphabetical once
prereqs exist. Which is the argument for checking.

## The trap worth carrying: systemd dlopens the TPM stack

The first enrolment produced an initramfs with the token handler in it and
**no libtss2 at all**. `copy_exec` follows ELF `NEEDED`, and that is not enough:

```
$ objdump -p libcryptsetup-token-systemd-tpm2.so | grep NEEDED
  NEEDED   libsystemd-shared-259.so
  NEEDED   libcryptsetup.so.12
  NEEDED   libc.so.6
```

and `libsystemd-shared` does not link the TPM stack either — it *dlopens* it,
and says so in its own metadata:

```
[{"feature":"tpm","description":"Support for TPM","priority":"suggested",
  "soname":["libtss2-esys.so.0"]}]
```

**Nothing that walks NEEDED can see a dlopen.** The hook has to name them:
`libtss2-esys.so.0`, `libtss2-mu.so.0`, `libtss2-rc.so.0`, and one level
further down `libtss2-tcti-device.so.0`, which is what systemd reaches through
after building the string `device:/dev/tpmrm0` itself.

This will bite anything else that puts systemd functionality in an initramfs.

## And the diagnostic rule bit a second time

S3 ended with *a diagnostic must be checked against the thing it claims to
check*. It went wrong here in the same shape, one step further out.

The initramfs check asserted five libraries, one of which was
`libtss2-tctildr.so.0`, and failed a perfectly good image for its absence.
`tctildr` is not on this path at all: `libtss2-esys` does not link it, and
`libsystemd-shared` contains no `Tss2_TctiLdr_*` reference — it dlopens the
device TCTI directly. The assertion had invented a requirement, and would have
sent the next reader looking for a packaging bug that does not exist.

The check now names `libtss2-sys.so.1` instead — which *is* a real transitive
dependency, so the assertion fails if `copy_exec`'s ELF walking ever stops
working.

## PCR 7 is real here

Worth stating because it decides whether any of this means anything:

```
PCR 7 before enrolment:
  sha256:
    7 : 0xC86235C7DCE44D53492AD174CE28D0C93CA59B341000534038036DBF1D9E1B8C
```

Not zeros. AAVMF genuinely measures Secure Boot policy into PCR 7, so sealing
against it binds the key to the firmware's SB state rather than to nothing. A
firmware without TCG2 support would have made the whole exercise vacuous while
still "passing".

## What this does NOT prove

| Not covered | Why it matters |
|---|---|
| A real TPM | `swtpm` reports manufacturer `IBM` and is libtpms, not silicon. Timing, NV wear and vendor quirks are untested. |
| Real OEM Secure Boot keys | `AAVMF_VARS.ms.fd` is Ubuntu's convenience image of the Microsoft KEK/db, not an OEM's db with its own additions and dbx. |
| Tamper-proof variables | **arm64 has no SMM**, so the SB variable store is not protected the way it is on x86. Signature *enforcement* is real; the threat model is weaker, and this is a platform property, not a bug. |
| What happens when PCR 7 changes | Sealing to PCR 7 survives kernel and initramfs updates (they are not measured there) but **not** a Secure Boot policy change — a shim/dbx update or toggling SB will drop the machine back to the passphrase. Nothing here tested that, and a fleet needs a recovery story before it happens. |
| Enrolment during install | `os7-setup` must do this in its configure step (L17). The spike enrols on a system that has already booted once with a passphrase. |
| amd64 | Same reason as S3: no amd64 ISO exists yet. |
| L18 — `bpool` vs Intune's encryption check | Untouched. Needs a real enrolment, not a VM. |

## Practical notes for whoever runs it next

**It is slow, and not because of the work.** Ubuntu's AAVMF drives a
238-column serial console, and GRUB's 30-second `recordfail` countdown takes
**10–15 minutes of wall time** to render over it. Each of the four phases is one
boot. Budget an hour for `run-s4.py all`; the actual enrolment takes seconds.

**Where the firmware comes from.** Homebrew's QEMU ships no Secure-Boot aarch64
firmware — there is `edk2-i386-secure-code.fd` and `edk2-x86_64-secure-code.fd`
and no aarch64 equivalent, nor any aarch64 vars template. `run-s4.py` pulls
`qemu-efi-aarch64` out of the `ubuntu:26.04` container into `.vm/firmware/`
(gitignored) on first use.

**swtpm** comes from Homebrew (`brew install swtpm`) and is started with
`--flags not-need-init,startup-clear`, because AAVMF on arm64 does not reliably
send `TPM2_Startup` and an un-started TPM answers everything with
`TPM_RC_INITIALIZE`.

S4 works on a **copy** of `.vm/s3/s3-target.qcow2`, so S3's result stays
reproducible. `./run-s4.py reset` throws the copy away.
