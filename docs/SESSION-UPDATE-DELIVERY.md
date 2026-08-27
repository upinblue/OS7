# Session — the update train arrives: packages on the ISO, channels, a hotfix, the firstboot runner, and the unattended check

**2026-08-28, on the x64 Windows host**, in a worktree branched off `8700095`
while the Active Directory session held the main tree. The update train was
code that arrived nowhere: the ISO did not install the nine packages, nothing
read `/var/lib/os7/migrations/pending`, one channel existed and no hotfix
path, and §6's unattended operation was a quoted requirement. This session
built the four missing pieces and ran the end-to-end gate on this machine —
the VM-harness port that made that possible is its own story,
[SESSION-VM-HARNESS-PORT.md](SESSION-VM-HARNESS-PORT.md).

Four decisions were made for this session before it started and are recorded
here rather than re-litigated: C7a stays open (development key everywhere,
`-AllowDevelopment` stays mandatory, `"development": true` in every
descriptor — including one in a channel named `stable`); the shipped
`OS7_REPO_URI` stays `file://` + `Enabled: no` and the end-to-end transport is
a local HTTP server; both hosts must keep working; scope is everything except
key custody.

---

## 1. The ISO installs the packages (C7's second half)

`build.sh` builds the nine .debs (plus the theme on amd64) from the same
sources the repository is built from, stages them as files, and the new hook
0022 installs them — os7-release first and alone (it diverts
`/usr/lib/os-release`; everything after reads the branded identity), then the
rest in one apt transaction, verified from dpkg's records. Hooks 0020 and
0085 are deleted; 0050 and 0075 became verifiers of the packages' work.

What the switch surfaced, each measured:

* **The two `release.json`s resolved** the way C9 implies:
  `/usr/lib/os7/release.json` is what os7-release DECLARES, hook 0075's
  measurement moved to `/usr/lib/os7/image.json`, and the sidecar beside the
  ISO stays the measured file under its old name. `check-image.py` now
  requires the two to agree where they overlap and asks `dpkg -S`, file by
  file, who owns pwsh, the module, os7-setup, the console font, the release
  facts, the apt source and the migration runner.
* **The os7-module .deb carried two of five modules** (`for name in Zfs OS7`
  while the ISO staged five) — an apt-installed machine lost Net, Time and
  Systemd and the first network cmdlet would throw about a module nobody
  asked for. Fixed to all five with one manifest + one .psm1 per module in
  pkg_finish. The AD session found the same defect independently; the merge
  resolves toward its six-module version.
* **One signing key for ISO and repository** (`os7-signing-key.sh`, one
  GNUPGHOME mounted into both make targets): os7-release ships the trust
  anchor, and a keyring differing from the repository's key would refuse
  every update the same tree built. On the way in: **#97** (gpg cannot put
  its agent socket on a Windows bind mount, and the failure was silenced)
  and **#101** (a worktree made by Windows git is unreadable to WSL's).
* **`os7.sources` became a conffile.** Found by construction, confirmed by
  the gate: os7-release ships the apt source declared-and-off,
  `Set-OS7UpdateChannel` rewrites it, and a plain file would be REPLACED by
  dpkg on the first upgrade — the first update a machine ever took would
  have reverted the channel that delivered it.
* **My own first check died on quoting** — the hook grepped for
  `IMAGE_ID=os7` in a file whose generator always writes `IMAGE_ID="os7"`,
  and one full ISO build paid for re-learning #37 (source os-release, never
  scrape it).

## 2. Channels and the hotfix form (§7, UL3)

`build-os7-repo.sh`: `OS7_CHANNEL` is the caller's (the pin used to clobber
the env, which is why only `index/development.json` had ever existed); the
index entry derives from the descriptor instead of restating it (they had
already diverged — the entry hardcoded `migrations: []`); and the hotfix form
exists: `OS7_HOTFIX_BASE` + `OS7_HOTFIX_DEBS`, with three refusals (base not
in this repository, base on a different snapshot, version moving more than
the Build field). The descriptor gains a `hotfix` block — base and overlay
packages with hashes, the overlay at C1's re-host degree — and the signed
index entry restates the base so applicability is decidable from the listing.

PowerShell: `Get-OS7ReleaseIndex` refuses an index whose document names a
different channel than its filename; `Get-OS7Release` emits
`Hotfix`/`HotfixBase`, cross-checks entry against descriptor, and holds
`Applicable` to the exact base; `Update-OS7` refuses a hotfix of a base the
machine does not run even by explicit `-Version`.

Measured: `check-update-logic.py` **32 checks** (the six new ones: stable
channel found, dev-key-under-stable-label still needs `-AllowDevelopment`,
mislabelled index refused, matching hotfix applies, foreign-base hotfix not
chosen and refused by name), `Test-OS7Update` **31**, and
`check-os7-repo.py` **67** — which now builds two channels and a REAL hotfix
(a `less` out of the pinned snapshot, re-versioned `+os7hf1`), installs the
stable base by exact version and applies the hotfix with one
`apt full-upgrade`: os7-base moves on the Build field alone, the overlay
beats the frozen snapshot, the machine's release.json names the hotfix.
On the way: **#98** — apt satisfies a strict `Depends (= old)` from CANDIDATE
versions only, so exact-version installs of old releases need the same
preferences pin `Update-OS7` already carries.

## 3. The firstboot migration runner (C10 §6')

`os7-migrations-firstboot.service` + `/usr/libexec/os7-migrate-firstboot`,
shipped and enabled (by symlink, the backup units' way) in os7-release.
Pending entries are validated against the one directory os7-release owns —
the file is an instruction to run code as root — runs are stamped under
`/var/lib/os7/migrations/<version>/` (Update-OS7's own convention, so retries
skip what ran), a failure keeps the pending record and fails the unit loudly,
and everything logs to the same `/var/log/os7/update.log`.

The first real migration is UL1's: `50-tpm2-reseal` asks whether the TPM2
seal opens against THIS boot (tokens only), re-enrols when it does not, and —
when no secret is reachable — says so and exits 0, because that is U8, it is
open, and a permanently red unit would bury the message. #100 measured the
exact case it exists for, on the first amd64 boot this repository ever made.

Migrations are AUTHORED in `build/packages/os7-release/migrations.d/` and
shipped under the version being cut — a tree directory cannot know the Build
number git will assign. The consequence (every release re-introduces an
unretired migration under its own version) is deliberate, right for UL1, and
written into the shipped README with the retirement path.

Measured in the container (`check-os7-repo.py`): runs and stamps; a second
run skips; an entry outside the migrations directory is REFUSED, not run.

## 4. Unattended operation (§6)

`os7-update-check.timer` + `.service` + `/usr/libexec/os7-update-check`, in
os7-release, one script for the timer, Intune and Arc. Two decisions taken
with numbers rather than left open:

* **Check and stage, never activate** — §4.2 step 10 is the operator's
  reboot; a staged environment is inert.
* **Daily**, chosen against the HOTFIX path: a monthly check would leave an
  out-of-band security fix unseen for weeks, the regression UL3 exists to
  prevent. U5's monthly *release* cadence is untouched.

The exit-code contract is explicit (and `SuccessExitStatus=0 2` keeps the
staged state green in systemd): **0** nothing to do — including "no channel
configured", the shipped state; **2** staged, reboot pending; **1** failed —
including a configured channel that does not answer, because a check that
could not run must never read as clean. Unattended runs never pass
`-AllowDevelopment` silently: the operator says it once in
`/etc/os7/update.conf`, which a rollback reverts.

## 5. The gate (run-s5.py update / timer)

*(This section is written before the gate has run and will be replaced by its
measurements; if you are reading this sentence in a commit, the run below did
not finish and this document says so.)*

## 6. What was expressly NOT measured

* **Nothing arm64.** No arm64 ISO was built from this branch, no arm64 VM
  booted; the Mac owes `run-s5.py all`, `run-phase3.py all` (still the full
  #74 gate) and a `make build-arm64` + `check-image.py` over this branch's
  hook 0022.
* **No real tenant.** Intune remediations and Arc run-commands invoke the
  same `/usr/libexec/os7-update-check`; that they do so from an actual
  tenant is unproven and out of local reach.
* **The hotfix on a booted machine.** The hotfix form is container-proven
  (§2); the machine gate applies a full release. A hotfix through
  `Update-OS7` on a VM is one more `run-s5.py update` with a hotfix repo —
  wired, not run.
* **`run-backup.py`** stays never-run (B-5's words), now on both hosts.
* **C7a, deliberately.** Everything remains signed by the NOT FOR RELEASE
  key; `out/os7-gnupg` is gitignored and nothing from it may be published.
