# Session — Tailscale on an OS/7 machine (Phase 0 of the vendor-applications work)

**2026-11-09, x64 Windows host.** Bench `ts` (`os7lab.py`, amd64, KVM inside Docker Desktop),
installed Headless from `out/OS7-1.0.0.277-amd64.iso` — the sixth preview, published the same
day. Bench `tsgui`, installed Gui from the same medium, for §9. Tailscale **1.104.5** from
`pkgs.tailscale.com/stable`. The plan this feeds is [VENDOR-APPS-PLAN.md](VENDOR-APPS-PLAN.md).

The question: Tailscale is not in the archive the release pins. What happens on an OS/7 machine
when an administrator installs it the way Tailscale documents — to the update train, to a
rollback, to the firewall, to OS/7's login rules — and what would an OS/7 role have to do
differently? The owner had already decided the shape (generic mechanism, Tailscale as its first
consumer, Tailscale's stable channel, Tailscale SSH off, login interactive or by an auth key from
the secret store); this session measured before anything was written.

**No real tailnet was used.** At the owner's request nothing was tested against a Tailscale
account. The control server is **Headscale 0.29.6** in a container on the same host, with its
own DERP relay and a lab CA; the second node is a container. §2 says what that can and cannot
stand for.

## The answers

1. **Tailscale's repository carries three packages, and one of them is the trust anchor.**
   `tailscale-archive-keyring` ships `/usr/share/keyrings/tailscale-archive-keyring.gpg`, and
   `tailscale` Recommends it, so the documented install hands the vendor the key apt checks the
   vendor with.
2. **An origin pin confines the repository to one package**, in either stanza order. **A wrong or
   rotated key is silent**: `apt-get update` warns, exits 0 and keeps offering the old index.
3. **The documented install puts the node's private key inside the boot environment** and leaves
   the auto-update decision to the tailnet.
4. **`Update-OS7` took the vendor package along without a word.** The clone's `full-upgrade`
   moved tailscale 1.104.4 → 1.104.5 from `pkgs.tailscale.com`; neither the update log nor the
   result object mentions it. The `postinst` in the chroot did not touch the running daemon.
5. **A rollback takes the machine off the tailnet** when the state is in the boot environment, and
   **does not** when the state is on a dataset created before the package (§5, R1 against R2).
6. **An auth key reaches `tailscale up` from OS/7's secret store** through `Start-OS7Job -Secret`,
   and its value is nowhere a second account could read. The job reports success whether or not
   the login worked.
7. **ufw does not see tailnet traffic.** Tailscale's `ts-input` chain runs before ufw's and
   accepts everything on `tailscale0`.
8. **Tailscale SSH takes port 22 of the tailnet address away from OpenSSH**, and for a
   non-interactive session **falls back to running the shell without PAM when PAM refuses** — an
   expired account and `/etc/nologin` do not stop it. With a terminal the account stack holds.
9. **MagicDNS joins systemd-resolved per link** and leaves every other name where it was.
10. **`Install-OS7ContainerHost`'s range check is blind to a tailnet**, and Tailscale drops traffic
    from any `100.64.0.0/10` source that does not arrive on `tailscale0`.
11. **`apt purge` empties a state dataset and then fails**; `apt remove` masks the unit.
12. **Found in passing, and older than this work: `Get-OS7Version -CheckDrift` checks nothing on
    any machine**, for two independent reasons, and a correct check would refuse every update on a
    fresh install (§11).

---

## 1. The repository and the package (no VM)

Read on the host with `curl` and `gpg`, and in a throwaway `ubuntu:26.04` container.

| Reading | Value |
|---|---|
| `dists/resolute/{Release,InRelease}` | HTTP 200. `Origin: Tailscale`, `Label: Tailscale`, dated 2026-11-03, architectures `all amd64 arm64 armhf i386 mips* riscv64` |
| Signing key | `resolute.noarmor.gpg`: primary **`2596A99EAAB33821893C0A79458CA832957F5868`** (rsa4096, 2020-02-25, `[SC]`), one encryption subkey. `InRelease` is signed by the primary |
| amd64 index | 155 versions of `tailscale`, newest **1.104.5**; also `tailscale-nginx-auth` 0.1.1–0.1.3 and `tailscale-archive-keyring` 1.35.181 (`all`) |
| `tailscale` | `Depends: iptables`; `Recommends: tailscale-archive-keyring (>= 1.35.181), iproute2` |
| Files | `/usr/bin/tailscale`, `/usr/sbin/tailscaled`, `tailscaled.service`, `tailscale-online.target`, `tailscale-wait-online.service`, `/etc/default/tailscaled` (the only conffile) |
| `tailscaled.service` | `StateDirectory=tailscale` (0700), `CacheDirectory=tailscale` (0750), `--state=/var/lib/tailscale/tailscaled.state`, `--socket=/run/tailscale/tailscaled.sock`, `ExecStopPost=tailscaled --cleanup`, `Type=notify` |
| `postinst` | unmask; enable if it was enabled before (a new install counts as enabled); **if `/run/systemd/system` exists**: `daemon-reload` and `deb-systemd-invoke restart tailscaled` |
| `postrm remove` | **masks** `tailscaled.service` |
| `postrm purge` | `deb-systemd-helper purge`, unmask, **`rm -rf /var/lib/tailscale`**, under `set -e` |
| CLI 1.104.5 | `--auth-key` takes `file:<path>`; `up --json` prints the login URL; `set --ssh`, `set --auto-update`; `tailscale update [--track] [--version] [--dry-run] [--yes]` |

### 1a. Confining the repository (container)

A source with `Signed-By:` pointing at a keyring of OS/7's choosing, and

```
Package: *
Pin: origin pkgs.tailscale.com
Pin-Priority: -1

Package: tailscale
Pin: origin pkgs.tailscale.com
Pin-Priority: 500
```

| Package | Candidate |
|---|---|
| `tailscale` | 1.104.5 (priority 500) |
| `tailscale-archive-keyring` | **none** (−1) |
| `tailscale-nginx-auth` | **none** (−1) |

The same with the stanzas in the **reverse order**, and with `Pin: release o=Tailscale` instead of
the origin. `apt-get install -s tailscale` then installs `tailscale` alone: the Recommends cannot
be satisfied and apt skips it. `origin` is the host name apt derived from the URI; `o=` is what the
vendor's `Release` file says about itself.

**A key that does not match is a warning.** The Ubuntu keyring copied over the Tailscale one at
the `Signed-By:` path: `apt-get update` printed `NO_PUBKEY 458CA832957F5868` as `W:`, said *"the
previous index files will be used"*, and **exited 0**; `apt-cache policy tailscale` still offered
1.104.5. A vendor that rotates its key stops delivering updates and nothing reports it.

## 2. The bench tailnet, and what it stands for

A lab directory on the build host, outside the repository (VENDOR-APPS-PLAN §7 step 8 moves it
into `installer/testing/`):

| Part | What |
|---|---|
| Control | `headscale/headscale:0.29.6` (`sha256:cabe84f0…`), `server_url https://headscale.os7.test:8443`, TLS from a 30-day lab CA, prefixes `100.64.0.0/10` and `fd7a:115c:a1e0::/48` (Tailscale's own) |
| Relay | Headscale's embedded DERP, region 999, STUN 3478/udp; **`derp.urls: []`**, so no Tailscale-run relay is in the map |
| DNS | MagicDNS, base domain `tailnet.os7.test`, `override_local_dns: false` — Tailscale's own default for *Override local DNS* |
| Reachability | Both the bench guest (through slirp) and the client container reach the host as `host.docker.internal` = `192.168.65.254`. Measured: `tailscale ping` answered **direct** (`via 172.17.0.4`) in 5 ms; `tailscale netcheck` listed only the bench relay |
| Second node | `os7-tslab-client`: `ubuntu:26.04` with the 1.104.5 tarball, TUN, joined as user `lab@` (`100.64.0.1`) |
| Policy | `tag:os7-bench` owned by `lab@`; accept all; one `ssh` rule, `lab@` → `tag:os7-bench` as `autogroup:nonroot` and `root`, only to measure §7 |
| Bench preparation | the lab CA in `/usr/local/share/ca-certificates`, `headscale.os7.test` in `/etc/hosts`. Nothing else |

**What it stands for.** Everything in §3–§8 that happens on the machine is the client's code —
`tailscaled`, its netfilter and DNS handling, its SSH server and the account it runs a session
as — and the client cannot tell which control server it talks to. **What it does not stand for**
is the control plane's own policy: key expiry defaults, the admin console's auto-update default,
the announcement of a newer version (Headscale sends no `ClientVersion`), SSH *check* mode, and
whether Tailscale's ACL engine decides exactly as Headscale's does.

**Keys never appeared.** `tslab.py` asks Headscale for a key and hands it on over standard input:
to the client's `tailscale up --auth-key=file:/dev/stdin`, and into the bench's
`New-OS7Secret` (§6). The key for the bench is tagged `tag:os7-bench`, reusable, valid 24 hours
and **not ephemeral** — R1 and R2 reboot the machine, and an ephemeral node can be deleted while
it is offline, which would read as a lost identity without any rollback.

**A trap found on the way: `sudo -S` swallows the rest of standard input.** With the password and
then the key on stdin, the key reached neither `pwsh`'s `[Console]::In` nor bash's `read`. Bash
reading the password line itself and feeding `sudo -v` through a here-string, then `sudo -n` on
the same stdin, works — and only with the here-string: through a pipeline the two `sudo`s have
different parents and the second answers *"interactive authentication is required"*.

## 3. The documented install on an OS/7 machine

Bench `ts` after Setup, before anything: `sources.list` on the pinned snapshot; **four Microsoft
sources** in `sources.list.d` (azure-cli, edge, prod, vscode — on a Headless install too), the
Edge one rewritten by Edge's own `postinst` (*"THIS FILE IS AUTOMATICALLY CONFIGURED"*,
`repos/edge-stable`, its own keyring); `os7.sources` present and `Enabled: no`. `iptables` 1.8.11
(`iptables-nft`), `nftables` 1.1.6 and `ufw` 0.36.2 installed, ufw inactive, the nft ruleset
empty. networkd and resolved, `enp0s3` only. No `os7-automation` dataset, so no secret store.

Tailscale's documented route — keyring to `/usr/share/keyrings`, `tailscale.list`, `apt-get
install tailscale`:

| Reading | Value |
|---|---|
| Installed | `tailscale 1.104.5` **and `tailscale-archive-keyring 1.35.181`** (the Recommends) |
| Unit | enabled and active at once; `tailscale status`: *Logged out.* `tailscale0` exists before any login |
| State | `/var/lib/tailscale` on **`rpool/ROOT/os7_1.0.0.277_…`** — inside the boot environment. Before login `tailscaled.state` is 2 bytes; after it 2326 bytes holding `_machinekey`, the profile and its node key, beside `files/` (Taildrop), `profile-data/`, the DERP map and the daemon's own logs |
| Prefs | `AutoUpdate {Check: true, Apply: null}`, `RunSSH false`, `CorpDNS true`, `NetfilterMode 2` (on) |
| Before login | nft: empty `filter` and `nat` tables only |
| `Get-OS7NetworkAdapter` | lists `tailscale0` as Kind `Other`, MTU 1280 |

## 4. `Update-OS7` with the vendor source present

Tailscale downgraded to 1.104.4 first, so that the update had something to move. A release
1.0.0.278 built from the working tree by `os7lab.py release`, served to the bench.

| Reading | Value |
|---|---|
| The clone's `full-upgrade` | **`Upgrade: tailscale:amd64 (1.104.4, 1.104.5), os7-setup`** — in `/var/log/apt/history.log`, which the clone shares with the running system because `/var/log` is `rpool/DATA/log` |
| `update.log` | `apt: install os7-desktop=1.0.0.278, full-upgrade, autoremove`, then `DONE`. Nothing about Tailscale |
| The result object | `From`, `To`, `Applied`, `BootEnvironment`, `Activated`, `Migrations`, `Removed`, `Reason` — no field that could say it |
| Microsoft sources | in the clone and used; nothing newer was on offer that hour, so nothing moved |
| The running daemon | **untouched**: `MainPID` 2584 and `ActiveEnterTimestamp` 19:34:47 before and after, `NRestarts=0`, no stop in its journal. The `postinst` ran in the chroot (where `/run` is bound in, so `/run/systemd/system` exists) and its restart reached nothing |
| After the reboot | the new environment runs 1.104.5 with `tailscale.list` carried over, and `/var/lib/tailscale` **copied** into it — the node key is now in both environments |
| `rpool/DATA` | every child got a snapshot named after the new environment (11 of them) |

Two more things `Update-OS7` did that were already true before Tailscale: it rewrote
`ubuntu.sources` and left `os7.sources.dpkg-dist` behind.

## 5. A rollback, with the state in two places

The same sequence twice, from snapshot `tslab-ready` (277, secret store, lab CA):
install → log in from the secret store → `Update-OS7` to 278 → reboot → **log out and log in
again** (what a node-key expiry or a re-enrolment does) → `Restore-OS7` → reboot.

| | R1 — documented install | R2 — `New-OS7ServiceDataset -Name tailscale -Backup $false -NoLayout` first |
|---|---|---|
| State on | `rpool/ROOT/<be>` | `rpool/DATA/lib/tailscale` (the package's `StateDirectory=` took the mount) |
| Login in 277 | `os7-r1`, node key `3b680fc5…`, state `ba57acba…` | `os7-r2`, node key `3ed8906a…`, state `0a3ea546…` |
| In 278 after the update | same key, **identical state file** | same key, same state |
| Logout + login in 278 | node key `f892e022…` | node key `fbf7b62a…` |
| After `Restore-OS7` to 277 | state `ba57acba…` — the pre-update copy. **`NeedsLogin`**, a registration URL, *"machineAuthorized=false"* | state `03edb470…` — the current one. **`Running`**, node key `fbf7b62a…`, peer answers direct in 5 ms |

**R1 is a machine that has left the tailnet.** A server reached only over Tailscale is, after
the rollback meant to rescue it, a server nobody can reach. R2's dataset also got a snapshot from
the update's recursive `rpool/DATA` snapshot — so the node key sits in one snapshot per update on
the same pool. It was created with `-Backup $false`, so no snapshot policy and no replication
target sees it.

## 6. The auth key from the secret store

A fresh install has no secret store: `New-OS7ServiceDataset -Name os7-automation` creates it (and
puts it into the backup policy). Then, first with a dummy key and then with the Headscale key:

```powershell
Start-OS7Job -Name ts-login -Secret tailscale-authkey -TimeoutSec 120 -Command `
  '& /usr/bin/tailscale up --login-server=… --auth-key="file:$env:CREDENTIALS_DIRECTORY/tailscale-authkey" --hostname=… --timeout=60s'
```

| Reading | Value |
|---|---|
| Secret | sealed to the TPM (`tpm2`), 616 bytes (dummy) / 661 bytes (real), `-TestOpen` true |
| Inside the fence | the job runs as root under `ProtectSystem=strict`, reaches `/run/tailscale/tailscaled.sock`, and the daemon reads the file |
| Dummy key | `backend error: invalid key: unable to validate API key`, `rc=1` — and the unit **`Deactivated successfully`** |
| Real key | `rc=0`, `BackendState Running`, `100.64.0.2` |
| The value, anywhere a reader could find it | journal of the boot **0**, `/run` **0**, the job's directory **0**, `/var/lib/tailscale` **0** |
| After a refused key | `tailscaled` switches to interactive login and makes a new node key; `NeedsLogin` |
| Interactive | `tailscale up --json --timeout=15s` → `{"AuthURL": "https://…", "QR": "data:image/png…"}`, exit 0; `status --json` then carries the same `AuthURL` |

The job's success is the runner's, not the login's: the cmdlet that logs in has to ask the daemon
afterwards (P5).

## 7. What the firewall sees

After the login, `tailscaled` (netfilter mode `on`, through `iptables-nft`):

```
chain ts-input {
    ip saddr 100.64.0.2 iifname "lo" accept
    iifname "tailscale0" accept
    udp dport 41641 accept
    ip saddr 100.115.92.0/23 iifname != "tailscale0" return
    ip saddr 100.64.0.0/10 iifname != "tailscale0" drop
}
chain INPUT { … jump ts-input }        (and ts-forward, ts-postrouting, two mangle rules)
```

Routes go into **table 52** (one `/32` per peer, `100.100.100.100`, `fd7a:115c:a1e0::/48`) behind
`ip rule 5270`; the main table, which `Get-NetRoute` reads, is unchanged.

**ufw, enabled on top:** `allow in on enp0s3`, `default deny incoming`, `ufw enable`. INPUT became
`policy drop`, `jump ts-input` **first**, then ufw's chains. The client connected to
`100.64.0.2:22` over the tailnet; `ts-input`'s `tailscale0` counter rose by 19 packets. The host
firewall does not filter tailnet traffic; the tailnet's policy does. Every ufw rule OS/7 writes —
`Enable-OS7RemoteDesktop -AllowFrom` is one — is therefore no scope for a tailnet peer. (Measured
on port 22; the Remote Desktop daemon is not on a Headless machine.)

## 8. Tailscale SSH

`tailscale set --ssh` on the bench; `Set-OS7AccountLockout -Attempts 3` beforehand. Three lab
accounts: `tsplain`; `tslocked`, locked by three wrong OpenSSH passwords (faillock lists them);
`tsexpired`, `chage -E 0`. OpenSSH is reached through the bench's own port forward, Tailscale SSH
at port 22 of the tailnet address.

**Port 22 of the tailnet address answers `SSH-2.0-Tailscale`.** With Tailscale SSH on, OpenSSH
cannot be reached over the tailnet at all.

**A command, no terminal** (`ssh host 'cmd'` — scp, rsync, automation):

| Account | OpenSSH, password | Tailscale SSH |
|---|---|---|
| `tsplain` | in — `bash`, `loginuid` 1003, `POWERSHELL_TELEMETRY_OPTOUT=1` (pam_env) | in — `-bash` through `su -l`, **`loginuid` unset** (4294967295), telemetry 1 |
| `tslocked` | **refused** (faillock) | in |
| `tsexpired` | **refused** — `pam_unix(sshd:account): account tsexpired has expired` | **in** — `pam_unix(su-l:account)` refused it, `user@1002.service` failed PAM, and the shell ran **without PAM**: `/bin/bash`, no pam_env (telemetry unset) |
| any, with `/etc/nologin` present | **refused** | **in** |
| `root` | `PermitRootLogin prohibit-password` | **in** — the tailnet policy allowed `root` |

**With a terminal**, Tailscale SSH runs `login(1)` (PAM service `remote`): `tsplain` lands in
**PowerShell** (`PS /home/tsplain>`, the MOTD, a logind session); `tsexpired` is **refused** —
*"Your account has expired"*. So the account stack holds for a person at a prompt and not for a
command.

**Attribution** exists only in `tailscaled`'s own journal — `audit: SSH login: user=tsexpired
uid=1002 from=100.64.0.1 ts_user=lab node=lab-client.…` — with no `loginuid` on the
non-interactive path and nothing in utmp.

The faillock row is not Tailscale's alone: OpenSSH with a **key** skips PAM's auth stack too, and
would not consult faillock either (sshd's design; not measured here). The expired-account and
`nologin` rows are the difference: OpenSSH applies the account stack to a key login as well. On a
domain-joined machine `pam_sss` sits in that same account stack and carries AD's logon rules, so
a domain account those rules refuse would — by the same mechanism — run commands over Tailscale
SSH. No domain controller was attached to this bench.

## 9. The desktop machine

Bench `tsgui`, installed Gui from the same medium; first boot through GRUB's editor with
`plymouth.enable=0` (#191), TPM seal renewed as on `ts`. Tailscale installed R2's way (dataset
first) and logged in from the secret store as `os7-gui`, `100.64.0.4`.

| Reading | Value |
|---|---|
| Who manages the network | NetworkManager **active**, systemd-networkd **inactive**, resolved active; `/etc/resolv.conf` → resolved's stub |
| `enp0s3` | NetworkManager, connection `netplan-os7net` (Setup's netplan document) |
| `tailscale0` | NetworkManager lists it as type `tun`, state **`connected (externally)`**, with an in-memory connection named `tailscale0` and the address `100.64.0.4/32` — it observes the link and does not manage it |
| resolved | the same as Headless (§7): `tailscale0` carries `100.100.100.100` and the routing domains, `enp0s3` keeps `10.0.2.3`; `lab-client.tailnet.os7.test` answered via `tailscale0`, `snapshot.ubuntu.com` via `enp0s3` |
| netfilter | the same `ts-input` chain as Headless |
| `Get-OS7NetworkAdapter` | `tailscale0`, Kind `Other`, MTU 1280, `100.64.0.4/32` |

Nothing on the desktop machine behaves differently from the Headless one in what this plan depends
on. Not looked at: what GNOME's network indicator shows for a `tun` device that NetworkManager calls
externally connected.

## 10. Two collisions

**The container host.** `Install-OS7ContainerHost`'s range check collects the machine's addresses
and its main-table routes. On the logged-in bench: addresses `10.0.2.15/24`, `100.64.0.3/32`;
routes `10.0.2.0/24`, `10.0.2.2`, `10.0.2.3`.

| `-Bridge` | the check says |
|---|---|
| `100.64.0.1/24` (the cmdlet's own help example) | collision — only because the node's own `/32` lies inside |
| `100.65.0.1/24` | nothing |
| `100.100.0.1/24` | nothing |
| `10.213.0.1/24` (the default) | nothing |

A veth pair standing in for a bridge: a "container" at `100.65.0.2` pinging the host at
`100.65.0.1` got **no answer**, and `ts-input`'s `100.64.0.0/10 … drop` counter went 0 → 13; the
same in `10.213.0.0/24` answered and the counter stayed. Any bridge range inside `100.64.0.0/10`
is dropped on a tailnet node, wherever the node's own address is.

**Removal.** `apt-get remove tailscale` **masks** `tailscaled.service` and keeps the state.
`apt-get purge` with the state on a dataset: the `postrm`'s `rm -rf /var/lib/tailscale`
**emptied the dataset — the node key with it** — then failed on the mount point (*"Device or
resource busy"*), dpkg reported the post-removal script failed, and the package was left `ic`.

## 11. The drift check, found in passing

`Get-OS7Version -CheckDrift` on the fresh 277: **`Unknown`** — *"the release manifest records no
packages_manifest hash to compare against"*. The hash is in `/usr/lib/os7/image.json`
(`sha256:77f5b583…`); `Get-OS7Version` reads `release.json`, which stopped carrying it when the
declared and the measured release facts were split (C7).

Called with the right hash, `Get-OS7PackageDrift` **throws**: without `-Installed`, `@($Installed)`
of an unbound `[string[]]` is `@($null)`, whose `Count` is 1, so dpkg is never asked and
`[Array]::Sort` gets `$null`. `Update-OS7` calls the drift check inside `try { } catch { }`, so its
refusal of a drifted machine has never been able to fire.

With both worked around by hand: **`Drifted`, 1527 packages, five removed** — `casper`,
`cifs-utils`, `finalrd`, `localechooser-data`, `user-setup`, which Setup removes at the end of
every install (apt's history shows the `autoremove`). A correct check would therefore refuse
`Update-OS7` on every freshly installed machine. The vendor-source work needs the check (it is
how an intended vendor package is told from an accident), so its repair is in the plan's first
phase.

## 12. Tailscale's own updater

In R1 the control server's default was off and the node stored `AutoUpdate.Apply: false` at its
first login. In R2 Headscale's `auto_update.enabled: true` (*"clients that have not made a local
opt-in / opt-out choice run auto-updates by default"*) and the node stored **`Apply: true`** — the
tailnet's administrator, not the machine's, decided whether `tailscaled` runs apt.

Headscale announces no client versions, so the automatic trigger could not be watched here. What
the updater does when it runs, by `tailscale update --yes` with 1.104.4 installed: **`apt-get
install --yes --allow-downgrades tailscale=1.104.5`**, in the running system — beside OS/7's
update train, unrecorded, and able to move the package down as well as up. `tailscale.list` was
left byte-identical.

## 13. What was not measured

* **Tailscale's own control plane** (§2): its defaults, its version announcements, SSH check
  mode, its ACL engine.
* **A domain account over Tailscale SSH.** No DC on the bench; §8's mechanism is `pam_unix` in the
  same account stack `pam_sss` is in.
* **OpenSSH with a key against a faillock-locked account** (§8's caveat).
* **A tailnet peer against Remote Desktop's ufw scope** — the mechanism is §7's, the daemon was
  not running.
* **An older `tailscaled` on a newer state file.** In R2 both environments ran 1.104.5.
* **Edge's updater** (CURATION C15) — the second consumer of the plan, not built here.
* **arm64**, entirely.
* **The first boot of a fresh 277 bench** hung after the passphrase twice — BUILD-NOTES #188/#191,
  `splash` plus an answering serial harness — and was booted once with `plymouth.enable=0` from
  GRUB's editor; the TPM seal was then renewed against the bench's own PCR 7
  (`systemd-cryptenroll --tpm2-pcrs=7`) so that later reboots needed nobody. The bench is not a
  control for anything PCR-measured.

## 14. Snapshots left on the benches

`ts`: `installed`, `resealed` (277 as Setup left it, TPM renewed), `m2-278-manual` (§4, on 278),
`tslab-ready` (277, secret store, lab CA and a sealed Headscale key). `tsgui`: `installed`,
`tailnet-gui` (277 Gui, TPM renewed, lab CA, Tailscale on its dataset, logged in). The Headscale
keys expire 24 hours after they were made (2026-11-09, 18:54 and 19:50 UTC).
