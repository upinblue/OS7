# Session — the container engine on a ZFS root (O-M1)

**2026-10-29, x64 Windows host.** Bench `ctr` (`os7lab.py`, amd64, KVM inside Docker Desktop),
installed Headless from `out/OS7-1.0.0.245-amd64.iso`. Snapshots `installed` (as Setup left it)
and `ct3-docker` (the end of run B, kept for step 4 of
[CONTAINERS-PLAN.md](CONTAINERS-PLAN.md)).

The question was CONTAINERS-PLAN's **O-M1**: does the archive's engine work on OS/7's ZFS root,
which storage does it choose, does it create datasets, where does its data land relative to the
boot environment, and what does the backup policy then do with it.

## The answers

1. **It works.** The containerd image store's `overlayfs` snapshotter runs on OpenZFS 2.4.1 under
   kernel 7.0.0-31. Writing, deleting a file from a lower layer (a whiteout) and renaming a
   lower-layer directory all behave correctly, and nginx answered 200. containerd's `zfs`
   snapshotter reports `skip`. The legacy graph driver, run as a control, picks `overlay2` with
   `Backing Filesystem: zfs` and works too. **Neither creates a single dataset per layer**, so the
   fear CT3 was written around does not happen.
2. **A plain `apt install docker.io` splits the store across the boot-environment boundary.**
   Ubuntu's postinst creates `rpool/var/lib/docker` *by itself*: outside `ROOT`, but also outside
   `rpool/DATA`, outside every OS/7 inventory and outside the backup policy. Meanwhile
   `/var/lib/containerd` — which, with the containerd image store, holds the images **and every
   container's writable layer** — stays inside `rpool/ROOT/<be>`.
3. **Creating both datasets first, with AU6's verb, gives the layout CT3 wants, and the postinst
   steps aside.**
4. **The engine's default bridge, `172.17.0.0/16`, cut the machine off.** SSH died the moment
   `docker0` came up, because the SSH peer's address was in that range.

---

## 1. Run A — the operator's way

`apt-get install -y docker.io` from the pinned archive, nothing done first. The **only**
deviation from a plain install is `/etc/docker/daemon.json` carrying a bridge range (`bip
10.213.0.1/24`, pools `10.214.0.0/16`), written before the package, for §5's reason. It touches
no storage setting.

| Reading | Value |
|---|---|
| Installed | `docker.io 29.1.3-0ubuntu4.1`, `containerd 2.2.2-0ubuntu1.1`, `runc 1.4.0-0ubuntu1`. Recommends pulled `bridge-utils`, `pigz` and `ubuntu-fan` (apt's default; OS/7 does not set `Install-Recommends`) |
| Engine | server 29.1.3, API 1.52, MinAPIVersion 1.44 — the same as the container measurement M-CT2 |
| Storage | `driver=overlayfs`, `driver-type io.containerd.snapshotter.v1`. containerd snapshotters: `overlayfs ok`, `native ok`, `zfs skip`, `btrfs skip` |
| `/var/lib/docker` | **`rpool/var/lib/docker`** — a dataset that did not exist before the install |
| `/var/lib/containerd` | **`rpool/ROOT/os7_1.0.0.245_…`** — the boot environment |
| A container's writable layer | `upperdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/11/fs`, so inside the boot environment |
| A volume | `/var/lib/docker/volumes/data1/_data` on `rpool/var/lib/docker` |
| Datasets + snapshots | 25 before, **28 after**: `rpool/var` and `rpool/var/lib` (both `canmount=off`) and `rpool/var/lib/docker` |
| Overlay semantics | write ✓, delete-from-lower ✓, rename-lower-dir ✓ |
| Sizes after two images, one container, an 8 MiB volume | `/var/lib/docker` 34 M, `/var/lib/containerd` 64 M |
| Kernel | one line, `evm: overlay not supported` — EVM does not cover overlay mounts; informational |

**Control: the legacy graph driver** (`"features": {"containerd-snapshotter": false}`, same boot):
`driver=overlay2`, `Backing Filesystem: zfs`, `Native Overlay Diff: true`; a pull and a run
work; **28 objects before and after two pulls**. So even the old path creates no per-layer
datasets on this engine.

### What OS/7 makes of run A

| Cmdlet | Sees `rpool/var/lib/docker`? |
|---|---|
| `Get-OS7ServiceDataset` | **No** — it lists `rpool/DATA/lib/*` (authd, azcmagent, networkmanager, os7-domain-homes) |
| `Get-OS7BackupPolicy` | **No** — the defaults, unchanged |
| `Get-OS7BackupCoverage` | **No** — it asks about home directories |

The engine's volumes are outside the boot environment and in no snapshot schedule, and its images
and container layers are inside the boot environment. Nothing OS/7 has would say so.

## 2. Who made `rpool/var/lib/docker`

`/var/lib/dpkg/info/docker.io.postinst`, in Ubuntu's own words a *"dedicated ZFS docker dataset
to handle all children containers in a single, persistent, place."* The condition, read off the
script on the machine:

- `zfs` is executable and the module loads, and
- the pool is the one mounted at `/`, and
- `findmnt -n -o SOURCE /var/lib/docker` is **empty or contains `/ROOT/`**.

Then it runs `zfs create -o canmount=off <pool>/var`, the same for `<pool>/var/lib`, and `zfs
create <pool>/var/lib/docker`. A migration block below it renames datasets matching
`/var/lib/<64 hex>` out of `<pool>/ROOT` and destroys their `@autozsys_` snapshots. That is
Ubuntu's own scar tissue from the zsys era, when the legacy `zfs` graph driver made one dataset
per layer inside the boot environment. **It decides on its own where Docker's state goes on any
ZFS root**, and it knows nothing about `rpool/DATA` or containerd's root.

## 3. Run B — CT3's layout

From the `installed` snapshot, with the same `daemon.json`:

1. `New-OS7ServiceDataset -Name docker` → `rpool/DATA/lib/docker` at `/var/lib/docker`,
   `InBootEnvironment False`, `BackupPolicy added`.
2. `New-OS7ServiceDataset -Name containerd` → `rpool/DATA/lib/containerd`, the same.
3. Then **the same script as run A**.

| Reading | Value |
|---|---|
| `/var/lib/docker` | `rpool/DATA/lib/docker` |
| `/var/lib/containerd` | `rpool/DATA/lib/containerd` |
| writable layer (`upperdir`) | on `rpool/DATA/lib/containerd` |
| volume | on `rpool/DATA/lib/docker` |
| `rpool/var` | **does not exist** — the postinst saw a ZFS mount not under `/ROOT/` and stepped aside |
| Datasets + snapshots | 27 before, **27 after** the install, pulls and runs |
| Store datasets under the running BE | **0** |
| `sanoid --take-snapshots` | four snapshots each of `docker` and `containerd` (monthly/weekly/daily/hourly), taken with the container running; the container was still `Up` afterwards |
| Snapshot sizes | `containerd` refers 54.9 M, `docker` 8.25 M |

**Two things about AU6's verb, used for something it was not written for:**

- **It puts `state/` (mode 0700) into each root**: `/var/lib/docker/state` and
  `/var/lib/containerd/state`. Its own documentation says why — a service dataset gets its
  mount and `state/`. In an engine's data root that is a stray directory OS/7 invented. The
  engine did not mind. It is still a decision this layer should not be making for someone
  else's directory.
- **`-Backup` defaults to on, so the image store went into the snapshot schedule.** With the
  containerd image store, `/var/lib/containerd` holds the images *and* each container's
  writable layer. The images can be pulled again, and Docker discards the writable layer
  whenever a container is recreated. Snapshotting it hourly holds image blocks against V15's
  70/80/90 rule for nothing.

## 4. The lockout — `docker0` against the SSH peer

The first attempt at run A (the operator's way, nothing set) installed the engine cleanly — `dockerd`
was up about 106 s into the boot — and then **no SSH connection to the machine ever completed
again**. The serial console still answered, which is how the rest was found:

1. QEMU's slirp table (`info usernet`) showed the forwarded connections arriving from
   **`172.17.0.4`**. QEMU runs inside a Docker Desktop container, and slirp passes a
   non-loopback peer's real address through to the guest rather than substituting `10.0.2.2`.
2. Inside the guest, `ip route get 172.17.0.4` → **`dev docker0`**. The engine had taken
   `172.17.0.0/16` for its bridge, so replies to the peer went into an empty bridge.
3. **Deleting that route alone did NOT bring SSH back.** The route then read `via 10.0.2.2 dev
   enp0s2`. Packet counters showed SYNs reaching `prerouting` (19), surviving conntrack
   (`new` 2, `invalid` 1) and Docker's NAT chain (which was empty), and never reaching the
   `input` hook (0). Nothing was sent from port 22 (0). `TcpExtIPReversePathFilter` stood at 2.
   **Where the rest were dropped was not isolated.**
4. **Stopping the engine and deleting `docker0` brought SSH back on the next attempt.**
5. **Positive control:** with `bip`/`default-address-pools` set to `10.213.0.0/24` and
   `10.214.0.0/16` *before* the package, SSH survived the install, the pulls and the runs in both
   runs A and B.

**This is a bench trigger and a product fact.** How the bench hit it — QEMU inside Docker
Desktop, whose own bridge is `172.17/16` — is particular to this host. What it shows is not: an
OS/7 machine that installs the engine with its defaults stops answering **anyone** who reaches it
from `172.17.0.0/16`, at once and without a message. `172.16.0.0/12` is common in company
networks and VPNs. The administrator cut off is the one at the far end of an SSH session.

## 5. Not measured

- **What a rollback or an update does to the default layout.** It is deduced from the placement
  measured above, and that is all: `Update-OS7` clones the boot environment, so after the
  reboot containerd's root is the clone *as of the update*, while Docker's records in
  `rpool/var/lib/docker` are current. Writes to container layers between the clone and the
  reboot would be lost, and a `Restore-OS7` would take images and layers back while Docker's
  container records stay. **Owed** (O-M6 in the plan) — and run B's layout makes it moot,
  which is the point of CT3.
- The mode of `/var/lib/docker` after AU6's verb. The `ls -ld` in the script was swallowed by a
  quoting defect of my own (an apostrophe in a heading line). The `state/` directories read
  `drwx------` from PowerShell.
- Restoring a store snapshot. Only *taking* one was measured.
- The `journald` log driver (O-M3), the firewall (O-M2), arm64, a Gui install.
- Ubuntu's 29.1.3 CLI exit codes (O-M5) — not attempted here.

## 6. What it changes

In [CONTAINERS-PLAN.md](CONTAINERS-PLAN.md), done the same day:

- **CT1 stands.** The engine works on the root OS/7 ships.
- **CT3 is rewritten:** the store is **two** directories. `containerd` is a dataset that is
  **not** backed up; `docker` is a dataset that **is**. Both are created **before** the
  package, or the postinst decides instead. The install verb needs AU6's verb without the
  `state/` directory and with `-Backup:$false` for the image store.
- **CT7 gains the bridge:** the address ranges are OS/7's, written before the package, and
  checked against the machine's own addresses and routes and against the peer of the session
  doing the install. On a collision it refuses.
- **A machine where somebody already ran `apt install docker.io`** has a dataset nothing in OS/7
  sees, and its images in the boot environment. The cmdlets have to recognise that layout and
  say so, and moving it is a migration.

For [BUILD-NOTES.md](BUILD-NOTES.md) and the os7-lab skill's trap list — **not edited here**,
because another session has both open — two entries are owed:

- **`docker.io`'s postinst creates `<pool>/var/lib/docker` on any ZFS root**, and leaves
  containerd's root in the boot environment.
- **Docker inside a bench guest takes `172.17.0.0/16` and cuts the bench's SSH off**, because QEMU
  runs inside Docker Desktop.
