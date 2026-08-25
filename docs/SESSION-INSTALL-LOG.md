# Session — the install log outlives the install

**2026-08-25.** `os7-setup` wrote its log to `/var/log/os7-setup/setup.log` on the
**live** system. That is casper's RAM overlay. Screen 12 offers a restart, and the
restart discarded the entire record of the install — while screen 12 printed that
same path on the way out.

The fix is one step, `InstallLogStep`, last before `TeardownStep`. Getting there
turned up two things nobody was looking for, both of which would have made the
fix quietly worthless, and one wrong assertion of my own.

Claimed **L31** in `installer/SETUP-PLAN.md` §9 before writing the entry, per the
rule at the top of that section.

---

## 1. What was wrong

Setup's steps all prove their own work, and they say so in the log:

* `AccountStep` reads the hash length back out of `/etc/shadow` — `useradd` exits
  0 whether or not the account can log in
* `InitramfsStep` lists what the initrd actually contains
* `NetworkStep` reads back the unit netplan generated
* `BootloaderStep` checks the menu resolves a boot environment

On a machine that boots, nobody misses any of it. On a machine that boots
*wrong*, that is the only record of what was done to it — and it was already gone
by the time anyone could look, with screen 12 pointing at a filesystem that no
longer existed.

Found while writing Phase 3b, by a harness assertion that watched the serial
console for a line the console structurally could not carry. The assertion was
wrong; the gap it revealed was real.

---

## 2. Two things found on the way, both measured

### 2.1 The log was a 200-entry ring, and an install writes more than that

`Log` kept a `Queue<Entry>` capped at 200. A **dry run** writes **284 lines**
(counted, not estimated — `wc -l` on the live log after
`--dry-run --unattend`). A real install writes more.

So a copy made from that ring would have landed on the target looking complete,
with the first 84 lines already dropped off the front: the whole storage phase,
and the beginning of `AccountStep`. Exactly the proofs the file exists to carry,
missing, with nothing anywhere saying so.

`Log` now keeps every line. `Recent` is its last 200, which is what a screen
wants; `Transcript` is all of it, which is what a file wants. A 20 000-line cap
remains as a backstop against a loop nobody foresaw, and if it ever bites, the
transcript says so in its first line rather than being quietly short.

**Not** solved by reading the live *file* back instead, although the file is
complete: the `LiveOnly` marks (§3) live on the entries and not in the text, so a
copy made from the file could only be redacted by pattern — the thing the mark
exists to avoid.

### 2.2 Every image ever built shipped a build-time `setup.log`

(The byte count below is today's, with this session's extra checks in the
self-test. What shipped historically was the same file at whatever size the
self-test printed then — the mechanism is the claim, not the number.)

`Main` logs one line — `os7-setup starting (…)` — *before* it dispatches to
`SelfTest()`. Hook 0080 runs `os7-setup --self-test` **inside the chroot during
the ISO build**. So the build created `/var/log/os7-setup/setup.log` in the
image, and `unsquashfs` then put it on every machine Setup has ever installed:
build-time timestamps, in the directory screen 12 sends the operator to, under
the name the live log has.

Measured, in three steps rather than inferred in one:

| Question | Answer |
|---|---|
| Does `--self-test` create the file? | Yes — 3 993 bytes, in a container with `/var/log/os7-setup` removed first |
| Does hook 0080 run exactly that? | Yes — `"${BIN}" --self-test`, line 59, the only invocation in the build |
| Does `/var/log` survive into the image? | Yes — the shipped squashfs carries `dpkg.log` at 331 785 bytes and `bootstrap.log` at 154 101, both with build-time mtimes |

Fixed at the cause: `Log.MemoryOnly()`, called before Main's first log line when
`--self-test` is set. It sets the same latch the lazy file-open uses, so there is
no second path through `File()` that could behave differently. A diagnostic
should change nothing.

Verified on the shipped artefact, not on the binary: `/var/log/os7-setup` is
**absent** from `OS7-1.0.0.69-arm64.iso`'s squashfs, and `find … -name setup.log`
over the whole image returns nothing.

---

## 3. Secrets — measured, not reasoned about

The log holds a `run: …` line for every command, and it was about to be written
to a disk that persists. Three canaries through `--dry-run`:

```
--passphrase-file    CANARY-LUKS-PASSPHRASE-QQQ
--password-file      CANARY-ACCOUNT-PASSWORD-WW
--wifi-secret-file   CANARY-WIFI-PSK-EEE
```

**Zero hits** for all three, in the live log and in stdout. The mechanisms behind
that, each confirmed by reading the call rather than assuming from the name:

| Secret | How it travels | Why it is not in the log |
|---|---|---|
| LUKS passphrase | keyfile in `/run` (a tmpfs), deleted in a `finally` | the command line names the *file* |
| Account password | `ExecSecret("openssl", …, "-stdin")` | `ExecSecret` logs `<secret on stdin>` |
| Crypt hash | inside the chroot **script**, not on a command line | script text is logged only under `--dry-run`, where the hash is the constant `$6$dryrun$dryrun` (confirmed in the dry-run log) |
| Wi-Fi PSK | netplan file on the target | already plaintext there by L25 — not something this log makes worse |

`TargetRoot.Chroot` now logs what the scripts **say back**, which is the reason
this file is worth keeping at all. That output is clean: the closest any script
comes to a secret is the length of a SHA-512 crypt hash, which is the same number
for every password.

### What was *not* clean: four lines that describe a secret

`passphrase set (14 characters)` and three like it name a **length**. On the RAM
overlay that is a good diagnostic — it is precisely how the trailing-newline trap
in `--passphrase-file` shows itself, the file being one byte longer than the
secret. On a disk that persists it is a narrowing of the search space for anyone
who can read `/var/log`, and OS/7's first account is in `sudo`.

Both are true, so the line is kept where it is useful and dropped where it is
not. `Log.LiveOnly` marks it **where it is written**; the persistent copy carries
`[not kept]` in its place. Never matched afterwards: a redactor that greps for
`characters` falls out of step with the next caller silently, and in the
direction that leaks.

A redacted line is **replaced, not dropped**. A transcript that silently omits
lines lies about what happened.

---

## 4. What was built

| Where | What |
|---|---|
| `Diagnostics/Log.cs` | complete record instead of a ring; `Transcript(persistent:)`; `LiveOnly`; `MemoryOnly`; `Installed`; `Kept` |
| `Steps/SystemSteps.cs` | `InstallLogStep`, between `BootloaderStep` and `TeardownStep` |
| `Screens/CompleteScreen.cs` | screen 12 names `Log.Kept`, or says it could not save the log |
| `Screens/ErrorScreen.cs` | F2 passes `persistent: false` — `/tmp` is a tmpfs too |
| `Program.cs`, `Screens/LayoutScreen.cs` | the four length-naming lines become `LiveOnly` |
| `testing/run-phase3b-network.py` | five assertions in `boot`, and `ask_number` |

`Log.Export` takes `persistent:` with **no default**. Every caller has to answer
"does this outlive the restart?". When Phase 4 gives F2 removable media, it is the
parameter and not a comment that will make somebody notice.

### The file is `install.log`, not `setup.log`

`os7-setup` will one day run *on* an installed machine — §3 screen 1, `R=Repair` —
and create a real `setup.log` there. A record **of** an install and the log **of**
a running Setup are two different files and must not be able to land on top of one
another.

### What it cannot contain, and that is structural

The copy is the last thing that happens while the target is still mounted.
Everything after it is the disk being taken away, so `InstallLogStep`'s own proof
and `TeardownStep`'s pool-export check are not in the file. A record of an install
cannot hold the part where the disk stops being writable. Named in L31 rather than
left to be discovered.

---

## 5. The proof

`--self-test`, five new checks, all green — including the two that would have
caught §2.1 and the redaction going wrong:

```
SELFTEST ok   step order: the log is saved after the bootloader, before the export — bootloader at 8, log at 9, teardown at 10
SELFTEST ok   log: a live-only line is redacted out of the installation record
SELFTEST ok   log: the same line is intact in the live log
SELFTEST ok   log: the transcript keeps the first line after 400 more
SELFTEST ok   log: an ordinary line is in both transcripts
```

The last two are the pair that matters. "Redacted" alone passes on a redactor
that empties the file; "the first line survives 400 more" is the regression guard
for the ring.

Then the only evidence that counts — `run-phase3b-network.py install`, then
`boot`, which starts the disk **with no ISO attached**:

```
  boot — the installed disk alone, asked what address it has
      ok    the machine booted from the disk alone
      ok    the interface has 10.0.2.99/24 — the address that was typed
      ok    the default route goes via 10.0.2.2
      ok    systemd-networkd is running
      ok    /etc/netplan/01-os7-network.yaml is mode 0600 (L25)
      ok    the renderer on the disk is networkd (headless, D14)
      ok    /etc/resolv.conf points at the resolved stub
      ok    /var/log/os7-setup/install.log is on the disk, mode 0600 (16528 bytes)
      ok    it holds 15 step lines and AccountStep's /etc/shadow proof
      ok    the first step of the install is in it — not a tail
      ok    2 line(s) about a secret are redacted, none leaked (L31)
      ok    the live log's own path is absent — the copy is the copy
```

16 528 bytes, 179 lines, 15 steps — `Generating the host identifier` through
`Saving the installation record`. Built from `OS7-1.0.0.69-arm64.iso`.

The last line is the negative control. Without it every assertion above could be
passing on a file that arrived some other way, and the claim being made is
precisely that the live one is gone. It is also what would catch §2.2 coming back.

---

## 6. The assertion that was wrong, again

The first run of the new checks reported **`FAIL 10 redaction marker(s), 11 line(s)
still naming a secret's length`** against a file that had **zero**. It also
reported 8 step lines where there were 15.

All three numbers were the harness's own `OK`-marker counter. `ask()` returns
everything the console showed, which includes the shell **echoing the command as
it was typed**, and the parse was "the first bare integer in the text" — so it
found `8`, `10` and `11` in `printf 'OK%s\n' 8` and stopped there, before ever
reaching grep's answer.

That is BUILD-NOTES #16, which the harness's own `ask()` documents at the top of
the file, arrived at from the other direction: not *expect a marker the command
contains*, but *parse a value the command contains*.

`ask_number()` now wraps the question in `printf 'N=%s\n' $(…)` and searches for
`N=` followed by digits. The typed text contains `N=%s`, which has no digits in
it, so the echo cannot match. The same trap took the negative control too:
`test -e X && echo PRESENT || echo ABSENT` types **both** words, so `"ABSENT" in
out` was true whatever the answer was — it now reads `test`'s exit status.

And one that was merely weak rather than wrong: counting `[not kept]` unanchored
also counted the header line that *explains* the marker, so the check would have
gone green on a redactor that had stopped marking anything. Anchored at
end-of-line it counts entries, and the number dropped from 3 to 2 — which is the
right answer for a plan carrying a passphrase and an account password.

Three wrong readings, one right file. **A diagnostic must be checked against the
thing it claims to check** — and the way it was checked here was by reading the
file off the machine and comparing, not by re-reading the assertion.

---

## 7. What this does not do

* **No export to removable media.** Still Phase 4's, and still worth having: this
  puts the log where the *machine* is, which is no use if the machine will not
  start at all. The two are complements.
* **Nothing rotates it.** One install, one file. A second install over the same
  disk overwrites the boot environment anyway.
* **`Update-OS7` does not write one yet.** `TargetRoot` is parameterised for it
  (RELEASE-AND-UPDATE-PLAN §4.2) and `InstallLogStep` takes a `TargetRoot` like
  every other step, so the mechanism is in place; nothing calls it.
* **amd64 is unmeasured**, as everything else in Phase 3 is.
