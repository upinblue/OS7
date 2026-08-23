# Session S6 — does TPM2 auto-unlock survive the update cycle?

Answers spike **S6** from
[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §10, which exists
because [S4](SESSION-S4-SECUREBOOT-TPM.md) ended by naming what it had not
shown:

> Sealing to PCR 7 survives kernel and initramfs updates (they are not measured
> there) but **not** a Secure Boot policy change — a shim/dbx update or toggling
> SB will drop the machine back to the passphrase. Nothing here tested that, and
> a fleet needs a recovery story before it happens.

That is a claim and an admission. S6 converts both into observations, and adds
the question neither S4 nor the release plan had an answer to: **is it
repairable?**

**Date:** 2026-08-23 · **Method:** a copy of the S4 system — disk, variable
store **and** the swtpm state directory, because the sealed key lives in the TPM
— booted six times under `AAVMF_CODE.secboot.fd` on arm64.

- The guest side: [`installer/spikes/s6-update-cycle.sh`](../installer/spikes/s6-update-cycle.sh)
- The harness: [`installer/spikes/run-s6.py`](../installer/spikes/run-s6.py)

```bash
./installer/spikes/run-s6.py all
```

## Verdict

| # | Question | Result |
|---|---|---|
| **Q1** | Does auto-unlock survive an initramfs rebuild? | **Yes.** PCR 7 is byte-identical across the rebuild and the next boot never asks. L17's premise holds. |
| **Q2** | What happens when Secure Boot policy changes? | **The seal stops opening, loudly and recoverably.** PCR 7 moves, `cryptsetup` refuses with a specific error, and the passphrase prompt returns. |
| **Q3** | Is it repairable without a reinstall? | **Yes, with the passphrase alone.** One `systemd-cryptenroll` re-seals against the new PCR 7 and the following boot is silent again. |
| **S6** | | **PASS** on arm64. **U8 now has a mechanism.** |

## Q1 — a rebuild changes nothing that matters

```
PCR 7 before rebuild = 0xC86235C7DCE44D53492AD174CE28D0C93CA59B341000534038036DBF1D9E1B8C
PCR 7 after  rebuild = 0xC86235C7DCE44D53492AD174CE28D0C93CA59B341000534038036DBF1D9E1B8C
```

Identical — and identical to the value S4 measured *before it enrolled anything*,
in a different session on a different copy of the disk. The measurement is
deterministic across runs, which is what makes sealing to it viable at all.

The rebuild was `update-initramfs -c -k all` followed by `-u -k all`: create
rather than update, which is the form a new kernel gets and the strictest version
of the question. What came back:

```
    ok       00os7tpm2 runs before cryptroot
    ok       token handler is in the initramfs
    ok       libtss2-esys.so.0
    ok       libtss2-mu.so.0
    ok       libtss2-rc.so.0
    ok       libtss2-tcti-device.so.0
    ok       libtss2-sys.so.1
```

**Both halves of Q1 had to hold and only one is about PCR 7.** The seal still
matching is necessary; the initramfs still being *able to use it* is the part
that could regress silently, because the token handler and the libtss2 stack are
not stock — S4 had to add them through `/etc/initramfs-tools/hooks/os7-tpm2`. A
rebuild that quietly dropped them would leave every machine auto-unlocking until
its next kernel update and then stopping. It does not: the hook survives, and
the ordering survives with it.

The boot after the rebuild reached a login prompt with no passphrase, on kernel
`7.0.0-30-generic`, root still `rpool/ROOT/os7_2026.08.1_202608230935`.

## Q2 — a policy change breaks it in the best way it could

```
PCR 7 with SB on  = 0xC86235C7DCE44D53492AD174CE28D0C93CA59B341000534038036DBF1D9E1B8C
PCR 7 with SB off = 0xB926225AC488E9C50EF2FA815AA7104B385A06907093BFB1DC62EEB7ABECDDF1
```

The seal does not open, and **the machine says exactly why**:

```
Please unlock disk os7_root: TPM policy does not match current system state.
Either system has been tempered with or policy out-of-date: Operation not permitted
```

*(`tempered` is upstream's spelling, quoted as printed.)*

This is the finding that matters, and it is better news than L17 implied. The
failure is:

* **not silent** — it names the cause, and names it in a form a script can match
  on. Compare S4's original problem, where a perfectly valid token simply did
  nothing and produced no error at all.
* **not fatal** — `--token-only` does not fall back to a passphrase itself, so
  the stock `cryptroot` prompt appears exactly as it always did. The machine is
  locked out of automation, not out of itself.
* **not ambiguous** — PCR 7 moved and nothing else did.

A fleet hitting a shim or dbx update therefore degrades to "every machine asks
for a passphrase at next boot". That is a bad morning, not a rebuild.

## Q3 — the recovery, which is what U8 was missing

Booted on the passphrase under the *new* policy, one command:

```
$ PASSWORD=… systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 …
New TPM2 token enrolled as key slot 2.
```

The old sealed slot was keyslot 1; the new one is keyslot 2. The next boot under
the same new policy:

```
Begin: Running /scripts/local-top ... os7-tpm2: unlocked os7_root from the TPM
```

**No passphrase, no reinstall, no touching the initramfs.** Re-enrolment writes
a LUKS token; the hook and handler S4 installed are what consume it. That
separation is why the repair is this cheap.

### What this makes possible for U8

The three properties together — a *detectable* failure, a *working* passphrase
path, and a *one-command* repair — describe an automatable recovery:

1. **Escrow a recovery passphrase at enrolment.** This is the part OS/7 still has
   to build, and the part that decides whether any of the rest is usable
   unattended. It is a key-management design, not a boot problem.
2. **Detect the fallback.** After a boot that used the passphrase rather than the
   token, a unit notices — the error string above is specific enough to match, and
   the token state is queryable with `cryptsetup luksDump` regardless.
3. **Re-enrol unattended on the next boot**, against whatever PCR 7 now reads.

Step 1 is the whole remaining problem. Steps 2 and 3 are demonstrated above.

**This does not close U8 by itself.** It converts it from "we do not know if this
is recoverable" into "recovery works; the open question is where the recovery key
lives". That is a much smaller question, and it is a Microsoft-stack question —
Entra, an OS/7-managed store, or Intune's own escrow — rather than a boot one.

## What this does NOT prove

| Not covered | Why it matters |
|---|---|
| **A real dbx update.** The policy change is simulated by swapping the Microsoft-key variable store for the stock empty one, i.e. turning Secure Boot off. Issuing a real dbx update needs a KEK private key nobody outside Microsoft has. | It is a proxy, chosen because PCR 7 measures Secure Boot *policy* and what needed characterising is the effect of that measurement changing — not which of several ways changed it. A real dbx update would move PCR 7 differently but arrive at the same place. Stated plainly rather than buried: this is the one substitution in S6. |
| **A real kernel package transaction.** The offline rebuild ran; `apt-get install --reinstall linux-image-$(uname -r)` was attempted and **skipped — the archive was unreachable from the guest**. | The offline rebuild exercises the part that can regress (the hook), which is why it is the primary test. But maintainer scripts did not run, so "a kernel update preserves auto-unlock" is shown for the initramfs mechanism and *inferred* for the package path. Worth closing when a guest with archive access exists. |
| **A real TPM.** `swtpm` again, as in S4. | Timing, NV wear and vendor quirks remain untested, and re-enrolment writes to the TPM every time it runs — a detail that matters more for an automated recovery loop than for a one-off enrolment. |
| **amd64.** | Same reason as S3 and S4: no amd64 ISO exists yet. |
| **A fleet.** One VM. | Nothing here says what happens when several thousand machines re-enrol on the same morning. |

## Practical notes for whoever runs it next

**It is much faster than S4, deliberately.** The first phase sets
`GRUB_RECORDFAIL_TIMEOUT=0` and `GRUB_TIMEOUT=1` in the guest. S4's "budget an
hour" comes from the harness powering guests off with `poweroff -f`, which makes
GRUB set `recordfail` and wait out its countdown over a 238-column serial console
on *every* subsequent boot. S6 needs six boots and would have cost an afternoon.
The setting touches nothing PCR 7 measures.

**Phases are independently re-runnable.** PCR values and results are carried in
`.vm/s6/state.json`, so `./run-s6.py policy` on its own still has the
Secure-Boot-on baseline to compare against.

**It works on a copy of `.vm/s4`, including the TPM directory.** Copying the disk
without `tpm/tpm2-00.permall` would produce a system that cannot unlock and a
spike that proves nothing. `./run-s6.py reset` discards S6's copy; S4 is left
alone.

**The harness fails rather than reporting a non-result.** If PCR 7 comes back
unchanged after the variable-store swap, `phase_policy` aborts instead of
recording a pass — a policy change that did not change the measurement would make
the phase vacuous while still "succeeding".
