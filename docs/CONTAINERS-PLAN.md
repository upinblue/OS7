# Containers — the engine, the cmdlets, and the window

**This file is authoritative for containers on OS/7: which engine runs them, where their data
lives, how PowerShell reaches them, who may see them, and the window an administrator controls
them from.**

**Proposed 2026-10-29; steps 1–4 and 6–8 are BUILT and have run on a machine since 2026-10-30**
([SESSION-CONTAINERS-WINDOW.md](SESSION-CONTAINERS-WINDOW.md)): `Install-OS7ContainerHost`
installed the archive's engine on an installed 1.0.0.264, and the Containers window drew it,
signed in through polkit, created a container and cleaned one up. The owner decided CT5's
channel and O-CT3 (both, the group as a root-equivalent opt-in) and moved a create dialog into
v1, against CT12. What is left is step 5 — the engine on an ISO — and phase 2. Decisions are CT1–CT12, open
questions O-CT1…, and a measurement still owed is `O-M…`, so the prefix tells "measured" from
"owed". The measurements in §2 were taken on the x64 Windows host the same day. **The engine has
run on an installed OS/7 machine the same day** (O-M1, M-CT7–M-CT10,
[SESSION-CONTAINERS-ZFS.md](SESSION-CONTAINERS-ZFS.md)), and that run rewrote CT3 and widened CT7.

It exists because of a request from the owner: *a GUI application, written in C#, in OS/7's design,
that controls our Docker containers, and that we can easily keep up to date.* Asked whether that
meant a tool for the development host or an application on OS/7 machines, the owner chose the
**product application** (2026-10-29).

That sentence needs three things before it can be a window, in this order:

1. **An engine on the machine.** There is none today: no package list, no hook and no cmdlet
   mentions Docker (grep, 2026-10-29: zero occurrences under `powershell/OS7/` and
   `build/config/package-lists/`).
2. **A PowerShell surface.** [GUI-APPS-PLAN.md](GUI-APPS-PLAN.md) G7: *an application may not
   exist with no cmdlet.*
3. **The window.**

Most of this file is about the first two, because that is where "easy to keep up to date" is
actually decided. A window over a surface that is right is small and stays small. A window that
has to know things is the part that rots.

Related authority: [GUI-APPS-PLAN.md](GUI-APPS-PLAN.md) G3–G12 (what an application may contain;
this is a member of that family); [POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md) P2,
P5, P6, P7, P10 and P12; [RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) D10, whose rule
already names *"a container store"* as the thing a rollback must not revert;
[AUTOMATION-PLAN.md](AUTOMATION-PLAN.md) AU6 (`New-OS7ServiceDataset`) and AU's secret store;
[CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) C8 (universe packages);
[VERSIONS-PLAN.md](VERSIONS-PLAN.md) V15 (the 70/80/90 pool rule).

---

## 1. Verdict

- **The engine is Docker Engine from the archive the release already pins** — `docker.io`
  29.1.3, API 1.52 — off by default and switched on by a cmdlet (CT1, CT2).
- **Its store is two datasets outside the boot environment, created before the package**,
  because D10 already said so and because Ubuntu's postinst otherwise decides by itself. The
  image store is not backed up; Docker's own root, which holds the volumes, is (CT3, M-CT8).
- **PowerShell speaks the Engine API over the socket, never the `docker` CLI**, because the CLI
  exits 0 for a start that started nothing and the API answers 304 (CT4, M-CT4).
- **Two modules, in P2's shape**: `powershell/Docker/` is generic, `OS7.Container.ps1` holds the
  judgement, and a layering rule keeps the socket in one place.
- **Seeing containers is root's**, which bends G6 for a measured reason: whoever holds the socket
  reads every container's environment (CT5, M-CT6).
- **The window is an MMC-style snap-in** in the classic idiom, a front-end and nothing else
  (CT9). Its details pane renders the cmdlet's object, so a new property costs no C# (CT11).
- **"Easy to keep up to date" is §3**: every fact in exactly one place, and a check on each seam.

---

## 2. What was measured, and what was not

All on 2026-10-29, on the x64 Windows host with Docker Desktop.

| # | Finding | How |
|---|---|---|
| **M-CT1** | The pinned archive (`20260921T000000Z`) offers `docker.io 29.1.3-0ubuntu4.1` (**universe**/admin), `containerd 2.2.2-0ubuntu1.1` (main), `runc 1.4.0-0ubuntu1` (main), `docker-compose-v2 2.40.3` (universe), `docker-buildx 0.30.1` (universe), `podman 5.7.0` (universe). There is no `docker-cli` package; `docker.io` carries the CLI. **`docker.io` declares `Conflicts: podman-docker`.** | `ubuntu:26.04`, sources replaced by the snapshot, `apt-cache policy` / `show` |
| **M-CT2** | That engine, running: **server 29.1.3, API 1.52, MinAPIVersion 1.44**. Storage is the **containerd image store** (`driver=overlayfs`, `driver-type io.containerd.snapshotter.v1`), not the classic graph drivers. cgroup v2. The socket is `root:docker 0660`; the package creates group `docker`. | `docker.io` installed from the snapshot in a privileged throwaway container, `dockerd` started by hand. **The backing filesystem was Docker Desktop's, not ZFS** — see O-M1 |
| **M-CT3** | The pinned pwsh 7.6.5 has `Invoke-RestMethod -UnixSocket` and reaches the engine with **no docker CLI and no `Add-Type`**: `/version` and `/containers/json` answer. | `os7img:175` with Docker Desktop's socket mounted (engine 29.7.2, API 1.55, min 1.40). The image is not the ISO (#93), but this is a property of the pinned pwsh |
| **M-CT4** | **The engine says when nothing happened; the CLI does not.** API: create → 201, start → 204, start again → **304**, stop → 204, stop again → **304**, delete → 204, delete again → 404. CLI: `docker start` on a running container and `docker stop` on a stopped one **both exit 0**. | API: pwsh against a throwaway `alpine` container, removed afterwards. CLI: Docker Desktop's 29.7.2 client. Ubuntu's 29.1.3 CLI was not measured (O-M5) |
| **M-CT5** | **The minimum API version moves**: 1.40 on 29.7.2, 1.44 on 29.1.3. A client asking for `v1.24` is refused with HTTP 400, *"client version 1.24 is too old"*. | Both engines above |
| **M-CT6** | **Holding the socket means reading every container's environment.** A `SECRET_TOKEN` passed at create came straight back from `/containers/<id>/json`. | Throwaway container |
| **M-CT7** | **The engine works on OS/7's ZFS root.** containerd's `overlayfs` snapshotter on OpenZFS 2.4.1 / kernel 7.0.0-31: write, whiteout, rename of a lower directory all correct, nginx served. `zfs` snapshotter `skip`. The legacy driver, as a control, picks `overlay2` on `Backing Filesystem: zfs`. **Neither creates a dataset per layer** (25→28 objects in run A are M-CT8's three datasets; 27→27 in run B). | Installed 1.0.0.245 Headless on bench `ctr` ([SESSION](SESSION-CONTAINERS-ZFS.md) §1, §3) |
| **M-CT8** | **A plain `apt install docker.io` splits the store across the boot-environment boundary.** Ubuntu's postinst creates `rpool/var/lib/docker` by itself, outside `ROOT` but also outside `rpool/DATA`, and `Get-OS7ServiceDataset`, the backup policy and `Get-OS7BackupCoverage` do not see it. `/var/lib/containerd` — the images **and every container's writable layer** — stays in `rpool/ROOT/<be>`. | Same bench, run A; the condition read off `docker.io.postinst` on the machine (SESSION §2) |
| **M-CT9** | **Creating both datasets first makes the postinst step aside.** `New-OS7ServiceDataset -Name docker` and `-Name containerd` before the package: both roots on `rpool/DATA/lib/*`, `rpool/var` never created, nothing under the running BE, sanoid snapshots both with a container running and the container survives. The verb also puts a `state/` directory into each engine root, and adds the image store to the backup policy. | Same bench, run B (SESSION §3) |
| **M-CT10** | **The engine's default bridge `172.17.0.0/16` cut the machine off.** The SSH peer arrived from `172.17.0.4`; once `docker0` came up, no new SSH connection completed. Deleting `docker0` brought SSH back at once. With the ranges set to `10.213.0.0/24` / `10.214.0.0/16` before the package, SSH survived both runs. | Same bench (SESSION §4). The bench's trigger is QEMU inside Docker Desktop; the fact is the engine's default |
| **M-CT11–14** | **The generic layer works against both engines**: 304 is `AlreadyRunning`/`AlreadyStopped`, logs are demultiplexed by stream, a real permission denial reads as the sentence CT5 needs, and the bridge range is readable for CT7's check | [SESSION-DOCKER-MODULE.md](SESSION-DOCKER-MODULE.md) |

**Not measured, and owed before anything is locked:**

- ~~**O-M1 — the engine on a ZFS ROOT.**~~ **Answered 2026-10-29** by M-CT7–M-CT10.
- **O-M6 — what a rollback or an update does to an engine whose store is split.** It is deduced
  from M-CT8 and was not measured: the update's clone freezes containerd's root at the moment of
  the update while Docker's records stay current. CT3's layout is meant to make this moot, and
  a machine where somebody ran `apt install docker.io` before OS/7 had a verb for it is still
  exposed (O-CT7).
- **O-M2 — the engine against OS/7's firewall.** Docker writes its own nftables/iptables rules for
  published ports, ahead of the host's filter. That is upstream's documented behaviour and was
  not measured here.
- **O-M3 — the `journald` log driver** on this engine: that `docker logs` still reads it, and that
  a removed container's logs survive.
- ~~**O-M4 — the helper's cost.**~~ **Answered 2026-10-30** (M-CT15, M-CT22): `pkexec` is on the
  264 medium, in main; a call costs one cold `pwsh` as root; and `auth_admin_keep` holds across
  separate pkexec processes for about five minutes FROM SIGN-IN, not from last use — so an
  administrator working longer is asked again, which is polkit's default and the operator route's
  reason to exist.
- **O-M5 — Ubuntu's 29.1.3 CLI exit codes.** The nested daemon could not pull an image, so M-CT4's
  CLI half is Docker Desktop's client.
- **arm64**, entirely.

---

## 3. How it stays up to date — the owner's requirement, answered first

This repository knows what "hard to keep up to date" looks like, because it has paid for it: one
fact known in two places, and the copy that nobody was looking at drifting — #66, the netplan
renderer written twice, the cmdlet counts in prose that were wrong seven times. So the answer is
not "write little code". It is **every fact in exactly one place, and a check on every seam**.

| What changes upstream | The one place it lands | What catches it |
|---|---|---|
| The Docker Engine version | **The pin.** `docker.io` comes from the snapshot and moves with the release train; the window carries no update mechanism of its own (G10) | The fixtures below are re-recorded with the bump, the way `check-compat-windows.py`'s are re-recorded with pwsh |
| The Engine API's shape | **`powershell/Docker/`**, the one module that speaks HTTP to the socket. It names the API range it has fixtures for and negotiates down to the engine's version (CT4) | `Test-DockerModule` against **recorded** engine responses, one set per engine in the range — the Zfs module's pattern. Today: 29.1.3/1.52 and 29.7.2/1.55 |
| A judgement — what "needs attention" means, what `Remove` may delete | **`OS7.Container.ps1`** | `check-container-logic.py`: the decisions against a fake engine |
| A property an operator wants to see | **The cmdlet's object** | Nothing in the window changes: the details pane renders the object (CT11) |
| A new operation | **A cmdlet and its test**, then one line in the helper's verb table and one button | G12's cmdlet map — `check-installer-cmdlets.py`'s shape: every button names a cmdlet that exists, with parameters it has |
| The look | **`OS7.Ui`'s tokens** | `check-gui-tokens.py`, which already exists |
| The C# plumbing | **`OS7.Shell`**, shared and not copied | `check-gui-logic.py`, extended to the new application |

What that buys: a Docker release that renames a field turns one module's fixture test red, instead
of a window in front of an operator. **The window's own code is the part that changes least**, which
is the reverse of how a container GUI usually ages.

---

## 4. Decisions

### CT1 — The engine is Docker Engine from the pinned Ubuntu archive. Proposed 2026-10-29.

`docker.io`, `containerd` and `runc` from the snapshot the release already names (M-CT1).

**Not `docker-ce` from download.docker.com.** That repository has no snapshot service, so it would
repeat BUILD-NOTES #144 — the four Microsoft packages that can only be pinned by hand, or not at
all — for a component that gets security fixes often.

**Not Podman, and this was a close call.** Rootless Podman fits G5 better: each user's containers
are their own, and no root-owned socket exists to be held. Its Docker-compatible API would carry
most of CT4's module across. It is refused for v1 because the administrator this product is for
knows Docker (Docker Desktop's `docker-users` group is the same model as CT5's), because the owner
asked for Docker, and because `docker.io` conflicts with `podman-docker`, so the two cannot share the
`docker` name on one machine (M-CT1). Revisit if CT5's privilege cost turns out to be what operators
actually run into.

**The cost, named so nobody finds it in a build:** `docker.io` and `docker-compose-v2` are
**universe**. C8 decided that universe packages are carried in the OS/7 repository; that list grows
from four to six, and `docker.io` is the biggest rebuild-or-rehost job on it.

### CT2 — The engine is a role: off by default, switched on by a cmdlet that asks the engine back. Proposed 2026-10-29.

Not every OS/7 machine runs containers, and a container engine holds a root socket and rewrites the
firewall. So the packages are available from the repositories the machine already trusts, and
`Install-OS7ContainerHost` (name open, O-CT1):

1. installs them at the release's versions,
2. creates the store (CT3),
3. writes `/etc/docker/daemon.json` (CT7),
4. enables `docker.socket`,
5. and then **asks the engine** — `/version`, `/info`, and the storage driver it actually chose —
   instead of reporting that `systemctl` exited 0 (P5).

Open: whether the role is a package the release metapackage `Recommends`, or an operator install that
`Update-OS7` has to carry into the next boot environment. The train's `autoremove` step makes that a
real question rather than a detail (O-CT2).

### CT3 — The store is two datasets outside the boot environment, created before the package. Proposed 2026-10-29, rewritten by measurement the same day.

D10 already decided this in its own words: rolling back a bad update *"would silently revert a
database, a container store, or anything else under `/var/lib/<service>`"*. What it did not know
was that **the store is two directories**, and that **the package picks a place by itself**
(M-CT8):

| Directory | Holds, with the containerd image store | Dataset | Backed up |
|---|---|---|---|
| `/var/lib/containerd` | images, and every container's writable layer | `rpool/DATA/lib/containerd` | **No.** Images can be pulled again. Docker discards a writable layer whenever the container is recreated, so data that must survive belongs in a volume. Snapshotting it hourly holds image blocks against V15 for nothing |
| `/var/lib/docker` | volumes, container records, networks | `rpool/DATA/lib/docker` | **Yes.** The volumes are the workload's data |

**Both are created before `docker.io` is installed.** Ubuntu's postinst creates
`<pool>/var/lib/docker` whenever `/var/lib/docker` is unmounted or under `/ROOT/`, and steps aside
when it is already a ZFS mount anywhere else (M-CT9). So the order IS the decision: dataset
first, package second. The other order leaves a dataset OS/7 does not see and the image store in
the boot environment.

**AU6's verb is the mechanism, and it needs two changes to serve here** (M-CT9). It must not put
`state/` into an engine's root: that directory is for OS/7's own services, and in somebody else's
data root it is a decision this layer has no business making. And it is called with
`-Backup:$false` for the image store. The first is a change to `New-OS7ServiceDataset`, the second
is a caller passing an argument.

The fear this section used to end on — a snapshotter making one dataset per layer, a recursive
policy snapshotting every one, V15 thinning a user's history to make room for images — **did not
happen**: neither the containerd snapshotter nor the legacy driver created a single dataset
(M-CT7).

Snapshots of the two are not atomic with each other, and need not be: the one that is restored
is `docker`, and what is restored from it is a volume, by file (`Restore-OS7File`), not the
dataset by rollback.

### CT4 — The cmdlets speak the Engine API, not the docker CLI. Proposed 2026-10-29.

**M-CT4 is the reason.** The CLI exits 0 for a start that started nothing and a stop that stopped
nothing; the API answers 304. That is P5 handed to us by the protocol, and wrapping the CLI would
throw it away — the repository's most expensive bug shape, *a program reported success and the
thing did not change*, chosen on purpose.

It also means JSON comes from the engine rather than from a `--format` template (G4's rule, one layer
down), and the cmdlets do not depend on a second binary's version moving on its own. M-CT3 shows the
pinned pwsh does it with `Invoke-RestMethod -UnixSocket` and nothing else.

**The API version is negotiated, never hard-coded.** The module names the oldest API it has fixtures
for, asks `/version` once per session, and uses the lower of the engine's version and the newest one
it has tested. M-CT5 is why: the engine's minimum moved from 1.40 to 1.44 between two 29.x builds,
so a hard-coded version is a refusal waiting for an engine update. Below the module's minimum it
refuses **by name**, giving both versions.

Compose is the exception — it has no API — and is phase 2 (CT10).

### CT5 — Seeing containers is root's, and G6 bends here for a measured reason. Proposed 2026-10-29.

G6 says reading is unprivileged and the window draws everything before anyone authenticates. For
containers that is not available. By Docker's own documentation, holding the socket is equivalent to
root, and M-CT6 shows that a reader sees every container's environment, which is where people put
database passwords. So:

- **OS/7 adds nobody to the `docker` group, and the window never asks to.** An explicit opt-in is
  O-CT3.
- **The window draws its frame and says so:** *"Containers are administered as root. [Sign in…]"*,
  and polkit's dialog appears on that click. That keeps G6's real point, which is that the prompt
  appears at the moment it can be honestly explained.
- **The channel is a helper with a fixed set of verbs**: `pkexec /usr/libexec/os7-container-helper
  <verb> <args>`, a `pwsh -File` script whose verbs are a `ValidateSet`. Each verb calls exactly one
  OS7 cmdlet and writes `ConvertTo-Json`. This is not `pkexec pwsh`, which G5 refuses as a whole
  shell as root. It is a verb table, and **the verb table IS G7's map**.
- **polkit**: listing and start/stop/restart → `auth_admin_keep`. Remove and prune → `auth_admin`
  every time. Local active sessions only, like `49-os7-update.rules`. How the helper tells the two
  actions apart (two paths, or `pkcheck` for the destructive verbs) is step 6's.

**Why not `os7-update@`'s templated unit.** That pattern is for one long operation whose progress goes
to the journal. A list is a request with an answer, and a unit per refresh is the wrong shape.
**Why not a filtering proxy daemon.** It would be a second API to keep up to date, which is exactly
what §3 exists to prevent.

This narrows GUI-APPS-PLAN's open question 3 for one application. It does not answer it for the
family.

### CT6 — The default view is what needs attention. Proposed 2026-10-29, corrected in step 3 the same day.

P10's shape, as the device manager has it. `Get-OS7Container` returns the containers that need
attention, and `-All` returns the rest. Each state comes with a sentence and a command, and **the
order of the rules is part of the decision**:

| State | Attention | What the engine says | Why it needs saying |
|---|---|---|---|
| `RestartLoop` | yes | `restarting` | P5's own example: `systemctl is-active` says `active` for a unit in a restart loop, and Docker's `running` is the same trap |
| `Unhealthy` | yes | `running`, health `unhealthy` | "running" is true and is not the answer |
| `OutOfMemory` | yes | not running, `OOMKilled` | **Checked before the signal rule**: the kernel's kill leaves 137, the same as a stop that timed out |
| `StartFailed` | yes | not running, `State.Error` set | The engine could not start it — a port taken, a mount missing. This is the reliable form of "it should be running and is not" |
| `Failed` | yes | exited, code neither 0 nor a signal's | |
| `Dead`, `Unknown` | yes | the engine's `dead`; a status this OS/7 does not know | A state the product does not know is not one it may call fine |
| `Stopped` | **no** | exit 0, **or 130/137/143** | What `docker stop` leaves behind. Reading these as failures would put every deliberately stopped service in the attention view |
| `Running`, `Starting`, `Paused`, `Created`, `Removing` | no | | |

**Two rules of the first draft did not survive step 3** ([SESSION-CONTAINER-STATES.md](SESSION-CONTAINER-STATES.md)).
*ShouldBeRunning* — stopped while the restart policy says `always` — would have fired on nearly
every deliberate stop. An `always` container that crashes is restarted by the engine itself, and
the API does not say who stopped one. `StartFailed` replaces it. *RestartCount rising* needs two
readings over time, which is polling (G10), so the engine's `restarting` decides and the count is
reported beside it. **P6 holds without either:** `RestartPolicy` is shown beside `State`, and
`PortsConfigured` beside `Ports`, never merged.

The window's state column reads these words. It never derives them.

### CT7 — The engine's configuration has one writer. Proposed 2026-10-29.

`/etc/docker/daemon.json` is written by `Install-OS7ContainerHost` and by nothing else, and the
cmdlet reads it back. The one setting decided here is **`"log-driver": "journald"`**. Container logs
then go to the journal, which `/var/log` keeps outside the boot environment, readable with
`journalctl CONTAINER_NAME=…`, and still there after the container is removed (O-M3 owed). The
default bind address is O-CT4.

**The bridge's address ranges are OS/7's too, and they are checked before they are written**
(M-CT10). The engine's default is `172.17.0.0/16` for `docker0`, then further `172.x` ranges for
every network it creates. On the bench, the moment `docker0` came up, the machine stopped
answering the SSH peer it was being installed from, because that peer was in the range. A
company network or VPN in `172.16.0.0/12` meets the same wall, and the person cut off is the
administrator at the far end of the session. So `Install-OS7ContainerHost` writes `bip` and
`default-address-pools` into `daemon.json` **before the package starts the engine**. It compares
the ranges with the machine's own addresses and routes and with the peer of the session doing
the install, and it **refuses** on an overlap, naming both. Which ranges it proposes by default is
O-CT6.

### CT8 — A published port says who can reach it. Proposed 2026-10-29.

Docker publishes ports through rules of its own ahead of the host's filter — upstream's
documented behaviour, **unmeasured on this product** (O-M2). REMOTE-DESKTOP-PLAN refuses to open
a port with no source scope. The container window cannot refuse, because the container already
exists, but it can say what the port is bound to: **`8080 → 80/tcp · all networks`** against
**`8080 → 80/tcp · this machine only`** and **`· only on 10.0.0.5`**. `0.0.0.0`, `::` and an
empty address all mean every network, and the engine's two entries for one port published
everywhere are shown as one. A container on the **host network** publishes nothing and is
reachable on every port it opens, so it gets that sentence rather than an empty list. The words
are a property of `Get-OS7Container`, not text the window composes. Until O-M2 is measured they
claim nothing about a firewall.

### CT9 — The window is MMC's idiom: tree, list, details, status line. Proposed 2026-10-29.

The reference a Windows administrator already has is *Computer Management* and the *Services*
snap-in. G8 takes the information architecture from the reference and the chrome from OS/7 Classic:

- **Tree:** Containers · Applications (Compose projects, by label) · Images · Volumes · Networks ·
  Engine.
- **List:** Name, Image, State (CT6's word), Ports (CT8's words), Restart policy, Created.
- **Details:** the selected object's properties (CT11).
- **Toolbar and context menu:** Start, Stop, Restart, Logs…, Remove…; Refresh is F5.
- **Status line:** engine and API version, counts, and how full the pool is — V15's reading,
  because images are the usual reason a pool fills.

Restart policies keep Docker's own words. Mapping them onto Services' *Startup type* was considered
and refused: `on-failure` and `unless-stopped` have no Windows equivalent, and a translation that
loses meaning is worse than an unfamiliar word.

### CT10 — v1 operates what exists; deploying is phase 2. Proposed 2026-10-29.

**v1:** list, inspect, start, stop, restart, logs (the last *n* lines), remove, images and volumes
listed, and prune with a preview of what it frees, from the engine's `/system/df`.

**Remove, corrected in step 3.** The first draft had it *"refuse when volumes are attached"*. That
protects the wrong thing: named volumes survive a container's removal, and anonymous ones do too
unless `-RemoveVolumes` is given. What a remove destroys is the container's **writable layer**,
which CT3 keeps out of the backup on purpose. So `Remove-OS7Container` is `ConfirmImpact High`,
the engine refuses a running container without `-Force` in its own words, and the result names
the **`KeptVolumes`**. A guard on the writable layer itself — refuse when the container has changed
files outside its volumes — needs the engine's `/containers/{id}/changes`, which the Docker layer
does not read yet. That guard is owed.

**Phase 2:** Compose `up`/`down` from a file through the `docker compose` CLI, wrapped in the generic
layer the way Hardware wraps `dkms`, because Compose has no API; registry credentials through AU's
secret store, never as plain text in the engine's `config.json` (P7); and the `/events` stream, so the
window can follow changes without polling. G10 forbids polling, so v1 refreshes on F5 and after its
own actions.

### CT11 — The details pane renders the cmdlet's object; the window has no type for it. Proposed 2026-10-29.

G4 already forbids a DTO beyond what deserialises. This goes one step further, because it is what
makes §3's fourth row true: the details pane is a property grid over the JSON object the cmdlet
returned. Labels come from a short map, and anything unmapped is shown under its property name. **A
property added to `Get-OS7Container` appears in the window with no C# change.** Only the list's six
columns are named in code.

### CT12 — What the window deliberately does not do. Proposed 2026-10-29.

G10, applied:

- **No exec, attach or terminal into a container.** That is a general shell, which is G10's first
  line, and `docker exec` is one command away.
- **No image builds**, and no editing of Compose files.
- **No polling.**
- **No update mechanism of its own.** It ships in the image and moves with the train.
- ~~**No create-a-container wizard in v1.**~~ **Reversed by the owner 2026-10-30**: a create
  dialog is in v1, and it is still a front-end — *Check* is `New-OS7Container -ValidateOnly`,
  *Create* the same cmdlet. Named volumes only (CT3), and the environment's values never shown
  again. Compose files stay phase 2.

---

## 5. The layers

```
os7-containers            src/OS7.App.Containers — Avalonia, runs as the user.
   │                      Arranges, labels, confirms, reports. Decides nothing (G3/P12).
   │  OS7.Shell → pkexec /usr/libexec/os7-container-helper <verb> <args>     (CT5)
   ▼
os7-container-helper      root, a fixed verb table, one cmdlet per verb, JSON out
   ▼
OS7.Container.ps1         PRODUCT: Get-/Start-/Stop-/Restart-/Remove-OS7Container,
   │                      Get-OS7ContainerImage, -Volume, -Log, Install-OS7ContainerHost.
   │                      CT6's states, CT8's reachability, CT3's datasets.
   │  P2-docker: only through the generic layer — check-layering.py holds it at 0
   ▼
powershell/Docker/        GENERIC: Invoke-DockerApi (the ONE place HTTP meets the socket),
   │                      version negotiation, the engine's own objects. Knows nothing of OS/7.
   │  Invoke-RestMethod -UnixSocket /run/docker.sock
   ▼
dockerd 29.1.3            docker.io from the pinned archive (CT1)
```

`Invoke-DockerApi` is to this module what `Invoke-HardwareCommand` is to Hardware. That is also
where P2-hardware's lesson applies: the rule has to catch a call that routes *through* the invoker
and still decides, in the product layer, which endpoint to hit.

---

## 6. Order of work — one step at a time, each approved

1. ~~**Measure O-M1**~~ — **done 2026-10-29** on bench `ctr`
   ([SESSION-CONTAINERS-ZFS.md](SESSION-CONTAINERS-ZFS.md)). CT1 stands, CT3 is rewritten and
   CT7 gained the bridge. The bench keeps a snapshot `ct3-docker` for step 4.
2. ~~**`powershell/Docker/`**~~ — **done 2026-10-29**
   ([SESSION-DOCKER-MODULE.md](SESSION-DOCKER-MODULE.md)). Recorded against 29.1.3 on the bench
   and 29.7.2 on Docker Desktop. `Test-DockerModule` passes 58 checks here and 61 live on the
   bench, and P2-docker is the eighth layering rule, at 0. Each check was proven to fire on a
   copy. **Shipped since step 3's wiring**, in the `os7-module` .deb: the container cmdlets
   import it. Hook 0060 names every export and counts the engine recordings; `check-image.py`
   runs `Test-DockerModule` on the finished medium.
3. ~~**`OS7.Container.ps1`**~~ — **done 2026-10-29**
   ([SESSION-CONTAINER-STATES.md](SESSION-CONTAINER-STATES.md)). `check-container-logic.py`
   passes 86 checks over 19 situations, and `--prove` turns all seven planted defects red. The
   fake engine is the Docker module's own seam rather than a socket server: the socket was
   measured live in step 2, and a second imitation of the engine in Python is the copy §3 avoids.
   **Wired into the OS7 module the same day**, once the other session's files were committed:
   `powershell/OS7/OS7.Container.ps1`, in all four lists, and the Docker module ships beside it in
   the `os7-module` .deb, because a product cmdlet whose layer is missing answers "module not
   found". They first ran on a machine in step 4.
4. ~~**`Install-OS7ContainerHost`**~~ — **done 2026-10-30**, first run on bench `ctgui`: both
   stores before the package, `New-OS7ServiceDataset -NoLayout` (no `state/` in a foreign root),
   `daemon.json` with the ranges checked against addresses, routes and the open SSH sessions
   (read from `/proc/net/tcp`, because sudo drops `$SSH_CONNECTION`), then the package, then five
   read-backs. O-M3's first half measured; O-M2 and O-M6 still owed.
5. **Delivery of the engine**: package or role (O-CT2), and what `Update-OS7`'s `autoremove`
   does to an operator-installed engine. **C8's universe question is answered for machines
   installed from 264** (M-CT16): their sources reach `docker.io` in the pinned archive.
6. ~~**The helper and its polkit rule**~~ — **done 2026-10-30**: three wrappers in
   `/usr/libexec` (polkit decides by path), one trust-boundary script, `org.os7.containers.operate`
   (`auth_admin_keep`), `.destroy` (`auth_admin` every time) and `.install` (`auth_admin` every
   time, its own words) — the last because the owner asked that the window set the engine up
   itself (CT2's cmdlet, run from a button). O-M4 answered.
7. ~~**The window**~~ — **done 2026-10-30**: `src/OS7.App.Containers`, `--self-test` 58, and
   check-gui-logic.py holding the window's verb list equal to the module's, class for class.
8. ~~**`os7-app-containers`**~~ — **built and run on a machine 2026-10-30**; `os7-desktop`
   depends on it and hook 0022 installs it. A 1.0.0.266 medium built from the working tree
   carried it (`check-image.py`: only the development-key line red), and a machine installed
   from that medium set the engine up from the window's button. The manual's page from
   `shoot-manual.py` is owed.

Phase 2 (CT10) comes after all eight.

---

## 7. Open questions

- **O-CT1 — The install cmdlet's name.** `Install-OS7ContainerHost`, or Windows' own
  `Install-WindowsFeature -Name Containers`. P1a already supplies Windows names that Microsoft's
  module lacks on Linux, and this is one an administrator will type from memory.
- **O-CT2 — How the role is delivered, and what `Update-OS7` does with it.** A `Recommends` of the
  release metapackage, or an operator install that the boot-environment clone and `autoremove`
  must leave alone.
- ~~**O-CT3 — The `docker` group as an explicit opt-in**~~ — **decided by the owner
  2026-10-30: yes, beside the helper.** `Add-OS7ContainerOperator` (ConfirmImpact High) says
  root-equivalent in its result; the container verbs accept a process the socket answers
  (`Assert-OS7ContainerElevated`). Measured over SSH (M-CT27).
- **O-CT4 — The default bind address.** `127.0.0.1` in `daemon.json` is safe and surprising;
  Docker's `0.0.0.0` is familiar and open. CT8 says which one it is either way.
- **O-CT5 — arm64.** The engine and the cmdlets apply, since a server-only architecture runs
  containers more than anything else. The window does not (GL1).
- **O-CT6 — The default bridge ranges.** Any fixed choice collides with some network. A range from
  `100.64.0.0/10` (carrier-grade NAT, rarely routed inside a company) or from `10.0.0.0/8`
  (common, but larger and usually easier to step around) are the two candidates. CT7's check
  makes either one safe to propose, because it refuses the collision before the engine starts.
- **O-CT7 — Machines where somebody already ran `apt install docker.io`.** They carry
  `rpool/var/lib/docker`, which no OS/7 cmdlet lists, and an image store inside the boot
  environment (M-CT8). `Get-OS7Container` should recognise that layout and say so. Moving the
  data to CT3's layout is a migration, not a `zfs rename`, because half of it sits inside `ROOT`.

---

## 8. What this changes elsewhere — not edited in this session

Other sessions were working in the same tree, so these waited until their files were free. **Done
on 2026-10-29**, except where a line says otherwise:

- [CLAUDE.md](../CLAUDE.md)'s authority table: a row pointing here.
- [GUI-APPS-PLAN.md](GUI-APPS-PLAN.md) §6: Containers in the family table.
- [POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md): P2-docker beside the other layering
  rules. **The rule itself exists** in `check-layering.py` since step 2. Only the paragraph is
  owed, and so is CLAUDE.md's *"holds all seven"*, which is now eight.
- CLAUDE.md's command list: `Test-DockerModule`, `capture-docker-fixtures.py` and
  `check-container-logic.py`.
- **Wiring `OS7.Container.ps1` into the OS7 module** — done: its name in `OS7.psm1`, hook 0060,
  `build-os7-packages.sh` and `OS7.psd1`, the Docker module in `build.sh`, the package, hook 0060,
  `check-image.py`, `check-module-parts.py` and `run-surface.py`, and the counts — **176 of 313
  functions in eight modules**, which `check-module-parts.py` holds.
- [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) C8: the universe list.
  **Still owed**, and on purpose: it records a decision C8 has taken, and CT1 — which engine — is
  still *Proposed*. It belongs to step 5.
- [BUILD-NOTES.md](BUILD-NOTES.md): two traps from O-M1. First, `docker.io`'s postinst creates
  `<pool>/var/lib/docker` on any ZFS root and leaves containerd's root in the boot environment.
  Second, the engine's default bridge cuts off an SSH peer in `172.17.0.0/16`.
- The os7-lab skill's trap list: Docker inside a bench guest takes the address range QEMU's own
  Docker Desktop container comes from, and the bench's SSH goes with it.
