---
name: os7-lab
description: Drive a real, running OS/7 machine in QEMU — start a VM that outlives the session, type at its serial console, run cmdlets over SSH with real exit codes, take screenshots, and snapshot/restore the installed state in under a second. Use this whenever a question is about what OS/7 ACTUALLY does on a booted machine (what a cmdlet prints, whether a service runs, whether an update or rollback works, what the desktop looks like) rather than about what the code says. Also use it before claiming any behaviour of an installed OS/7 system.
---

# The OS/7 workbench

`installer/testing/os7lab.py` runs a VM that **outlives the process that started
it**, so a question about a booted machine costs a command rather than a boot —
and if there is no installed disk, rather than a 25-minute install.

Every other harness in `installer/testing/` is a batch run: it owns QEMU's
stdio and the machine dies with it. Those are the gates and they stay. This is
the bench beside them.

## Start here

```bash
python installer/testing/os7lab.py ls
```

Benches live in `.vm/<name>/`, laid out exactly like `vmscreen.Lab`'s
(`target.qcow2`, `edk2-vars.fd`, `tpm/`), so a bench can be opened on a machine
another harness installed — `up s5` boots run-s5.py's gate machine in place.

```bash
python installer/testing/os7lab.py up manual        # detached; returns in seconds
python installer/testing/os7lab.py login manual     # boot -> shell -> ssh key
python installer/testing/os7lab.py exec manual 'Get-OS7Version | Format-List'
python installer/testing/os7lab.py down manual      # ACPI, waits for a clean stop
```

To build a machine of your own — 18 Setup steps, about 25 minutes, and it ends
with an `installed` snapshot so you never pay for it twice:

```bash
python installer/testing/os7lab.py install lab7               # Headless, 24 GiB
python installer/testing/os7lab.py install gui --mode Gui     # the desktop, 40 GiB
```

`--mode Gui`, **not** `Desktop`: `InstallPlan.cs` declares
`enum InstallMode { Gui, Headless }`, which is not the word the plans and the
docs use for that product. Ask the C# before inventing a value.

## The three channels, and which one answers what

Each presupposes more of the machine than the last. **Which channel answered is
part of the answer.**

| channel | needs | use it for |
|---|---|---|
| `console` | a kernel | the initramfs passphrase, `os7-setup`, a machine with no network, and anything where a boot might fail. The only channel that can see a failure |
| `exec` (SSH) | network, sshd, PAM, an account | everything after login. Real exit code, stderr apart, `--json`, no quoting limit |
| `shot` / `key` / `type` / `click` (QMP) | only QEMU | the screen. The GUI, which on amd64 **is** the product |

A machine that answers `exec` has already proved four things. One that does not
has proved nothing about any of them — that is when to drop to `console`.

```bash
os7lab.py console manual --read --tail 40        # needs no running VM at all
os7lab.py console manual 'systemctl is-active ssh'
os7lab.py exec manual 'Get-OS7Service -OS7Only' --sudo --rc
os7lab.py exec manual 'Get-OS7BootEnvironment' --json --sudo
os7lab.py shot manual desktop                     # PNG under .vm/<name>/shots/
```

`--sudo` sends the password on stdin; it does **not** make the machine
passwordless, because the next thing that happens to a bench is a snapshot.

## Updates and rollback, driven by hand

`run-s5.py update` is the gate and stays it. This is the same machinery made
steerable, so you can look between the steps:

```bash
os7lab.py up gui --serve .vm/gui/repo     # serving is declared AT BOOT
os7lab.py login gui
os7lab.py release gui                      # builds the NEXT build after this bench's
os7lab.py exec gui 'Set-OS7UpdateChannel -Uri http://10.0.2.2:8907 -Channel development -Confirm:$false' --sudo
os7lab.py exec gui 'Get-OS7Release | Format-List' --sudo
os7lab.py exec gui 'Update-OS7 -AllowDevelopment -Confirm:$false' --sudo --timeout 3600
#   ... reboot, look, then:
os7lab.py exec gui 'Restore-OS7 -Confirm:$false' --sudo
```

**`--serve` must be given at `up`.** The guest reaches the host side of
user-mode networking at `10.0.2.2`, and that side is wherever QEMU's network
stack lives — inside the container on this host — so the directory has to be
mounted when the container starts. There is no way to start serving later.

`release` calls **run-s5.py's** `build_release_repo` with three globals
rebound, rather than reimplementing it: the repository must be signed from
`out/os7-gnupg`, whose public half the ISO ships, and a second copy of that
docker invocation is BUILD-NOTES #66 waiting to happen.

Take a snapshot before the update. `Restore-OS7` is the product's rollback and
is what you want to exercise; the snapshot is for when the run goes wrong.

## Snapshots are why this is cheap

**0.6 s to take, 0.7 s to restore** (measured, amd64, 5 GB disk). A snapshot is
**three things**: the disk, the firmware variables and the TPM state, taken
together with the VM **stopped**. Restore puts all three back.

```bash
os7lab.py down manual
os7lab.py snapshot manual clean
#   ... break things ...
os7lab.py down manual && os7lab.py restore manual clean && os7lab.py up manual
```

Take a snapshot named `installed` the moment a machine is installed, and start
every exploration from it.

## Rules that keep findings honest

**The bench is for LOOKING. A harness is what makes something true.** Forty
typed commands later the machine is not the one that came off the installer —
BUILD-NOTES #93 in a new place. Anything that is to count as evidence must be
reproducible by a `run-*.py` or `check-*.py` from a named snapshot.

**Do not claim what the bench did not see.** `login` reports the TPM only when
*this boot* printed no passphrase prompt, because a bench attaches to machines
that have been up for an hour. The same discipline applies to everything else
read off a long-lived machine.

**Say which host.** amd64 runs here (KVM in a container); arm64 runs on the Mac
(HVF, host process). The bench is symmetric by way of `vmarch.py`, but the
arm64 side is **unrun**.

## Traps this bench has already paid for

- **A terminal query answered late is a keystroke in the wrong field.** Replies
  go out from a thread within milliseconds. Answering from a poll loop put six
  cursor reports into a password field and cost two runs.
- **Never derive the machine's state from the log.** The log holds every boot
  this bench ever had. `probe_state()` presses Enter and reads who answers.
- **A newline sent down the serial line IS Enter.** Use `printf '%s\n' '...'`,
  never a second command carrying a literal newline (BUILD-NOTES #16).
- **Settle before typing.** A shell still painting its prompt eats the first
  characters, and nothing reports it.
- **A qcode is a KEY POSITION, not a character.** `type manual "a-b"` on a
  machine installed with `keyboard: de` put `aßb` on the screen: `minus` is
  where `ß` lives on a German keyboard. `type` takes `--layout` (default `de`,
  because that is what this repository's install plans set) and the table was
  verified by typing and reading the screen back, not copied from a keymap.
  `run-phase3.py`'s five-entry table is correct only while the guest is still
  on US layout — which it is during Setup and is not afterwards.
- **Git Bash mangles Unix paths passed to docker AND to this tool**
  (BUILD-NOTES #102). `push bench file /tmp/x` arrives as
  `C:/Users/…/Temp/x`; `push`/`pull` now refuse a Windows-shaped guest path and
  say which shell did it. Run these from PowerShell.
- **A reinstalled bench is a different machine.** Its host keys change, and
  `StrictHostKeyChecking=no` accepts an *unknown* host, not a *changed* one —
  so every command comes back wrapped in fourteen lines of
  REMOTE HOST IDENTIFICATION HAS CHANGED. `install` and `restore` drop the
  bench's `known_hosts` for that reason.
- **The bench is not a control for anything platform-measured.** It attaches a
  virtio GPU, an xHCI controller, a keyboard and a tablet that `run-s5.py` does
  not, and PCRs 0–7 measure the platform. A TPM result from this bench is not
  a TPM result about the product; `run-s5.py boot` is where that is measured.
  Use `up --no-gui` when the question is about sealing.
- **The host console must not decide what the guest may say**, and it tries
  twice. stdout is reconfigured to UTF-8 (a `systemctl status` once died on
  systemd's own `○`), and `subprocess` is given `encoding="utf-8",
  errors="replace"` — `text=True` alone decodes with the host's code page, so
  one em dash in a journal entry killed the reader thread, `p.stdout` came back
  None, and a cmdlet that returns 100 objects was published in a matrix as
  `empty`. Silent truncation is worse than a crash.

## When a bench will not come up

`os7lab.py status <name>` says what is running, which ports, and whether SSH
answers. If `up` reports the VM did not come up, it prints the container's last
20 log lines — QEMU rejects a bad argument there, not in Python.
