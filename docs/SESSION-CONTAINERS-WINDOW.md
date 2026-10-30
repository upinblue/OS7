# Session — the Containers window, its cmdlets, and the first engine on an OS/7 machine

2026-10-30, x64 Windows host. CONTAINERS-PLAN.md steps 4, 6, 7 and 8 in one
round, at the owner's request: *talk through what a good container server and
its application should do, ask, then implement PowerShell and GUI* — and, asked
how far, **to a run on a machine**.

## 1. What the owner decided

| question | answer | what it changed |
|---|---|---|
| Who may see and operate containers (CT5, O-CT3) | **the polkit helper, and the `docker` group as an explicit opt-in** | Both channels built; one verb table behind both |
| What goes into v1 beyond start/stop/restart/logs/remove | **images, volumes, networks and a clean-up; Compose applications; image-update detection; volume backup visible** — all four | Fifteen product cmdlets and ten generic ones |
| Deploying | **a simple create dialog now** | Reverses CT12's "no create-a-container wizard in v1". Compose `up` from a file stays phase 2 |
| How far | **to a run on a machine** | Steps 4, 6, 7 and 8 |

One option promised more than could be delivered. "Volume backup visible" said that *Previous versions…* would open the Versions window on a volume. That cannot work. A volume's data is under `/var/lib/docker`, which dockerd makes `0710 root:root` (measured, §4). The Versions window runs as the user by design (VERSIONS-PLAN V19). So the Containers window reads a volume's versions itself, through the root channel it uses for everything else, and shows the command that restores a file. §4 shows it working.

## 2. What was built

**The generic layer, `powershell/Docker/`, 12 → 28 functions:**

- **Creating and pulling:** `New-DockerContainer`, `Receive-DockerImage` (pull), and `Get-DockerDistribution` (what a registry says a tag names, without pulling).
- **Removing:** `Remove-DockerImage`, `Remove-DockerVolume` and `Remove-DockerNetwork`, each asking the engine back afterwards.
- **References:** `Split-DockerReference`.
- **This host's engine:**
  - the socket: `Test-DockerSocketAccess` (asked by opening the socket), and its group with `Get-`, `Add-` and `Remove-DockerSocketMember`;
  - `daemon.json`: `Get-` and `Set-DockerDaemonConfiguration`, read back key by key;
  - the package: `Get-DockerPackage`, `Install-DockerEngine` (candidate asked first, dpkg asked afterwards, `/_ping` waited for) and `Restart-DockerEngine`.
- **Its own guard:** `Assert-DockerElevated`, for #149.
- **Status in every refusal:** `Assert-DockerStatus` now carries the engine's status in `Exception.Data['DockerStatus']`, so 409 "in use" and 403 "built in" are told apart without matching the engine's prose.

**The product layer, `OS7.Container.ps1`, 6 → 25 exported functions:**
`Get-/Remove-OS7ContainerImage` (with `-CheckUpdate`), `-Volume` (backup,
newest snapshot, `-IncludeVersions`), `-Network`; `Get-/Start-/Stop-OS7ContainerApplication`
(Compose projects off their labels, dependency order); `Get-/Remove-OS7ContainerUnused`
(the clean-up); `New-OS7Container` (with `-ValidateOnly`); `Get-/Install-OS7ContainerHost`;
`Get-/Add-/Remove-OS7ContainerOperator`; `Get-/Invoke-OS7ContainerVerb`.

The container verbs now use **`Assert-OS7ContainerElevated`** instead of `Assert-OS7Elevated`. A process passes if it is root OR the socket answers it, because an operator in the socket's group is root-equivalent on purpose, and refusing them by uid would overrule the administrator. `New-OS7ServiceDataset` gained `-NoLayout`, so that no `state/` lands in another program's root. That was CT3's owed change.

**The window, `src/OS7.App.Containers`** (`os7-containers`):

- **Layout:** Computer Management's tree, list, properties and status line (CT9).
- **Dialogs:** a log, *New container*, *Clean up* and *Previous versions*.
- **What it decides:** nothing. Every state word, every refusal, every *Recommended* tick and every *Reachable* sentence is a cmdlet's.
- **Its one channel:** `OS7.Shell`, either directly (`pwsh` running `Invoke-OS7ContainerVerb`) or through `PolkitHelper` and `pkexec`.
- **`OS7.Shell` changes:**
  - `PolkitHelper.cs` builds `/usr/libexec/os7-…` itself and refuses any other name.
  - `PowerShellRunner` gained standard input, because a container's environment holds passwords and a command line is readable by every account.
- **`OS7.Ui` changes:** an edit field (`TextBox.field` inside a sunken bevel) and a fixed-pitch face (`os7_font_mono`).

**The package, `os7-app-containers`:**
- the window;
- `/usr/libexec/os7-container-helper`, `…-helper-destroy` and (§4a) `…-helper-install`, three wrappers, because polkit picks the action by the program's path;
- `/usr/lib/os7/container-helper.ps1`, the trust boundary: the channel comes from the wrapper, control characters are refused with `\z`, and the verb goes to the module's table;
- `org.os7.containers.policy`, which remembers the password for operating and asks every time for removing, with German messages.

`os7-desktop` depends on the package, hook 0022 names it, and `check-image.py` asks the medium who owns the window and both helpers.

## 3. Checks

| check | result |
|---|---|
| `check-container-logic.py` | **157 ok**, against 86 before. A second world covers images, volumes, networks, applications, the clean-up, the create cmdlet, the verb table, the operator and the ranges. `--prove`: **17 of 17 planted defects RED** |
| `Test-DockerModule` | **89 passed**, against both REAL recordings (29.1.3 on the bench, 29.7.2 on Docker Desktop) |
| `os7-containers --self-test` | **60 ok** on Windows and in `os7-build:amd64`, and during the package build |
| `check-gui-logic.py` | 48 ok, plus `--docker`: all three applications' self-tests. `--self-test` 6 of 6, two new: a Destroy verb mirrored as Operate, and pkexec named outside `PolkitHelper.cs` |
| `check-gui-tokens.py`, `check-layering.py` (8 rules, P2-docker at 0), `check-ps-traps.py` (6 held), `check-privilege.py` (42 / 41, at baseline) | green |
| `check-module-parts.py` | **39 ok** — after it went red on hook 0022 not naming the new package, which would have failed the next ISO build at apt |
| `Test-ZfsModule`, `Test-OS7Backup`, `check-image.py --self-test` | green |

## 4. On a machine — bench `ctgui`, 1.0.0.264 GUI, installed this session

The packages were built from the working tree **at the bench's own version
(1.0.0.264)** so that the installed metapackages' `(=)` dependencies held. That
is a bench measurement and **not a release**; the next ISO carries the real thing.

| # | measured | how |
|---|---|---|
| M-CT15 | `/usr/bin/pkexec` and `run0` are ON the 1.0.0.264 amd64 medium; pkexec `127-2ubuntu1.1` is in **main** and installed on the machine | `unsquashfs -l` of the medium; `apt-cache policy` on the bench. Half of O-M4 |
| M-CT16 | The installed machine's sources reach the pinned archive WITH universe: `docker.io` candidate `29.1.3-0ubuntu4.1` | `apt-cache policy docker.io` as root. C8's universe question is answered for a machine installed from 264: the package is reachable without the OS/7 repository carrying it |
| M-CT17 | **`Install-OS7ContainerHost` worked on its first run.** `rpool/DATA/lib/docker` (backed up) and `rpool/DATA/lib/containerd` (not) before the package; `rpool/var` never created; `/var/lib/docker` `0710 root:root` and **no `state/`**; `daemon.json` with the bridge, the pool and `journald`; `docker.io 29.1.3-0ubuntu4.1`, `containerd 2.2.2-0ubuntu1.2`, `runc 1.4.0-0ubuntu1`; SSH survived. Five read-backs, all true | the cmdlet's own checks, then `zfs list`, `stat`, the file and `Get-OS7BackupPolicy` asked separately |
| M-CT18 | The update-detection premise holds on BOTH engines: a just-pulled tag's registry digest is among the image's RepoDigests | `Test-DockerModule`, on each recording |
| M-CT19 | `New-OS7Container -ValidateOnly`, then the real thing: pulled (`Downloaded`), created, started, and nginx answered **200** on `127.0.0.1:8080` | as root over SSH |
| M-CT20 | The helper's boundary: through pkexec `host` answers `Root`; a Destroy verb sent to the operate helper is refused BY NAME and not run; a control character in an argument is refused (exit 2); a description on stdin reaches the verb through pkexec (it found a port clash) | `pkexec /usr/libexec/os7-container-helper …` as root |
| M-CT21 | **The window as a user who is not an operator:** the frame, CT5's sentence and *Sign in…*. polkit's dialog shows the policy's German message. Signed in, it drew the engine — the one failed container in *Needs attention*, the status line "Docker 29.1.3, API 1.52 · 3 of 4 containers running · 1 need attention · pool rpool 13% full (Normal) · signed in through polkit" | QMP screenshots `.vm/ctgui/shots/app2`–`app6` |
| M-CT22 | **`auth_admin_keep` holds across separate pkexec processes, for about FIVE MINUTES FROM SIGN-IN** — not from last use. The second half of O-M4. A removal asked again (the destroy action) while operating was still remembered; the clean-up's reload four minutes later asked for operating again | the window, through every node, then *Clean up* |
| M-CT23 | The create dialog: *Check* showed the cmdlet's plan ("6379 → 6379/tcp · this machine only", new volume, image present); *Create* answered "cache: Started, now Running" | screenshots `new1`–`new3` |
| M-CT24 | *Check for updates* asked Docker Hub for three images: all `Current`, nothing pulled | screenshot `img1` |
| M-CT25 | A volume's previous versions came from a real sanoid snapshot of `rpool/DATA/lib/docker`, read as root through the helper | screenshot `ver1` |
| M-CT26 | `docker logs` through the `journald` driver: the log window showed stdout and stderr, marked. The first half of O-M3; whether a removed container's log survives is still owed | screenshot `log1` |
| M-CT27 | The operator route: `Add-OS7ContainerOperator os7admin`, a fresh login has `docker`, `Get-OS7ContainerHost` says `Operator`, and `Stop-`/`Start-OS7Container` work WITHOUT sudo | SSH |

### What the machine found while every check here was green

1. **A verb's stdout carried PowerShell's warnings ahead of the JSON.** The window's first answer was *"'W' is an invalid start of a value"*. As a user, `Get-OS7StoragePressure` warns that the ESP is root's, and pwsh with stdout redirected writes the warning stream to **stdout**. This is BUILD-NOTES #60, the rule *"the IPC boundary suppresses the other streams by mechanism"*, missing at a new boundary. `Invoke-OS7ContainerVerb` now redirects `3>$null 4>$null 5>$null 6>$null`, and `check-container-logic.py` holds it with a REAL pwsh process. The in-process harness cannot see the defect, because there the streams stay streams. Planted, it goes red.
2. **"Data backed up: No" about a dataset that is backed up.** As a user, `/etc/os7/backup.json` is root's, `Get-OS7BackupPolicy` falls back to the default policy, and the default does not name the engine's dataset. `BackedUp` is now `$null` with a sentence when the policy could not be read, and the window says *Unknown*. Held and planted.
3. **The window's port properties were raw objects.** An object that carries a `Text` is now shown by it (CT8's sentence).

### What it found about the bench, not the product

The first boot of a freshly installed GUI bench needs the passphrase: the install-time TPM seal does not open on the bench's platform. Under `splash`, that prompt never reaches the serial console as text. `os7lab.py login` waited for it forever. Each probing Enter became an empty passphrase, and characters typed at the virtual keyboard only echoed on tty1. One boot with `plymouth.enable=0`, appended in GRUB's editor over the serial line, put the prompt on the serial console, and the harness typed it. This is BUILD-NOTES #188's family, written up as #191.

## 4a. Into the image — and the engine from the window

Asked the same day to put the window on the next release, the owner was asked one
more question. On a fresh machine the window said "no engine" and named a cmdlet to type. Should the window set the engine up itself? **Yes.**

**The engine is still NOT on the image**, and that is CT3, not caution: with
`docker.io` in the squashfs, `/var/lib/docker` would be inside every installed boot
environment before `Install-OS7ContainerHost` could put a dataset under it. So the window gained **Set up the engine…**, shown only when `Get-OS7ContainerHost`
says `NoEngine`. The cmdlet's answer now carries the command in #148's elevated
form (`sudo pwsh -NoProfile -c 'Install-OS7ContainerHost'`). The window had first spelled it itself, which `check-gui-logic.py` caught: a file that can invoke something named `sudo`.

**A third polkit action, `org.os7.containers.install`**, behind a third wrapper
`/usr/libexec/os7-container-helper-install`, and a fourth verb class, `Install`, whose only verb is `install-host`. The other two actions were refused for this, for these reasons:

- **The operate action** remembers the password for five minutes. Installing packages as root is not that.
- **The destroy action** would have asked in the words "remove containers, images, volumes" about something that removes nothing.

The window says what will happen before polkit asks (datasets, ranges, packages from the archive, network needed), runs the verb, reports the cmdlet's own read-backs one per line, and then signs in through the operate helper. The account that installed the engine is not in the socket's group, so polkit asks once more there.

`os7-app-containers` is in `os7-desktop`'s Depends and in hook 0022's set (which
`check-module-parts.py` required). `check-image.py` asks the medium who owns the
window, all three helpers and the policy.

## 4b. The new medium on a machine — 1.0.0.266, bench `ct266`

`make build-amd64` from the working tree (not yet committed, so `reproducible: false`)
gave `OS7-1.0.0.266-amd64.iso`. `check-image.py amd64`: **one** failure, the expected
one — a medium built without the release key trusts only the development key, which is
what a preview built for checking is. Everything else green, including
`os7-app-containers 1.0.0.266 installed` and `dpkg -S` naming it the owner of the window,
all three helpers and the policy. Hook 0022 installed it from the staged package, and
the build's own read-back said so.

A GUI machine installed from that medium (`os7lab.py install ct266 --mode Gui`, first
boot through #191) has *Containers* in the menu with nothing added by hand. On a machine
with no engine the window draws `NoEngine`, CT2's sentence, the elevated command and
**Set up the engine…** — and "Data backed up: —", not "No".

**The machine then found two defects in the button, both fixed before anything was committed:**

1. **It ran as the user.** The channel sent every verb directly unless the window was
   signed in through polkit — and on a machine with no engine nobody can be. The window
   showed `Install-OS7ContainerHost`'s own #148 refusal (honest, and useless). Now an
   Install-class verb always goes through its helper (`ContainerChannel.UsesHelper`,
   held by `--self-test`). polkit then asked in the install action's own words.
2. **It died asking whether its first dataset existed.** BUILD-NOTES #192: the root
   helper's `try`/`catch` turned a suppressed `throw` into a fatal one. Fixed with
   `Get-OS7ExistingZfsDataset`; `check-automation-logic.py` green.

**And a third outcome the day supplied by itself:** `snapshot.ubuntu.com` answered 502 and
503 from about 18:55. The button then failed where it should — *"apt-get install exited 100
and dpkg reports docker.io, containerd, runc not installed"*, with the archive's own lines
under it — after the datasets and `daemon.json` were in place (`Layout: OS7, Access:
NoEngine`), so a second press resumes rather than refuses. The window now asks the machine
again after a failure, so its properties show what the attempt left.

**When the archive answered again (19:30), the second press went through.** polkit asked in
the install action's words; the window reported the cmdlet's own read-backs — *"Installed:
Docker 29.1.3 (docker.io 29.1.3-0ubuntu4.1, containerd 2.2.2-0ubuntu1.2, runc
1.4.0-0ubuntu1)"* and five `ok` lines — then signed in through the operate action, and the
Engine node showed `Root`, `OS7`, `journald`, data backed up, images not, bridge
`10.213.0.0/24`. That is the whole path a person takes on the next release: install from
the medium, open *Containers*, press one button. Bench snapshot `engine-from-window`.

The two fixes and the re-ask landed as PACKAGES on that machine (built at 1.0.0.266), after
the medium was built. The commit carries them; the release is built from the commit.

## 5. Not measured

- **The engine on an ISO.** Every image still ships without it; step 5's delivery question (O-CT2) is open, and so is whether `Update-OS7`'s `autoremove` leaves an operator-installed engine alone.
- **O-M2**, the engine against the host firewall. CT8's words still claim nothing about one.
- **O-M3's second half**: whether a removed container's log survives in the journal.
- **O-M6**, a rollback over an engine whose store is in CT3's layout.
- **Compose `up`/`down` from a file**, registry credentials, the `/events` stream — phase 2.
- **The window under the operator route on a desktop** (measured over SSH only), and **with RDP**, where polkit's `allow_any` applies.
- **arm64**, entirely; the window does not apply there (GL1).
- **`check-gui-logic.py --docker`** ran before the last two window fixes; the package build ran the final self-test (58 ok) in the same image.
