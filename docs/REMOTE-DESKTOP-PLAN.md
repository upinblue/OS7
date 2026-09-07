# Remote Desktop — reaching an OS/7 machine over RDP

**This file is authoritative for how an OS/7 machine is reached over Remote Desktop: the mechanism,
what is authenticated where, what OS/7 owns versus what gnome-remote-desktop owns, where the
certificate and machine credential live, and — first — what was measured on a machine versus what is
still a claim about code or a web source.**

**It is a concept, not yet a decision.** Every `Rn` below is marked *Proposed 2026-09-06*, not
*Decided*: no code exists, no `OS7.RemoteDesktop.ps1` is in the tree, and the owner has accepted
nothing. Decisions are R1–R17, limitations RL1–RL13. Measured facts keep the dossier's own `M-R`
numbers (not renumbered); a measurement still owed is `O-R1…`, so the prefix tells "measured" from
"owed".

It exists because a question was put plainly — *"Can I `mstsc` into one of these machines the way I
would a Windows box — turn it on from PowerShell, have it be secure, and feel familiar?"* The machine
already ships a complete, mstsc-speaking RDP server; nobody had turned it into a feature, and this
file is how one would.

Related authority: [DECISIONS.md](DECISIONS.md) (Intune outranks preference; open questions 1
firewall, 2 rename, 9 keytab-in-BE); [POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md)
P1, P2, P4–P7, P9 and the Tier-2 gaps (Users, Firewall, Certificates — all "not started"), open
question 1; [AD-PLAN.md](AD-PLAN.md) for the two-stage-feature template, why Kerberos is stage
2, and AL5; [IDENTITY-PLAN.md](IDENTITY-PLAN.md) (OS/7 where a person looks, Ubuntu where
software does; the cert subject is a person-facing surface);
[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §4.4 and SETUP-PLAN D10 for what rolls
back; [BUILD-NOTES.md](BUILD-NOTES.md) #85, #110, #111, #86, #33, #93, #117, #118/#120; and the
administrator manual [docs/manual](manual/README.md).

---

## 1. Verdict

**A Windows administrator can type `mstsc /v:os7box`, be authenticated at the door by
NLA/CredSSP against a machine-wide RDP credential, and then be shown OS/7's own branded GDM
login screen over the wire, where they sign in a second time as themselves — and the mechanism
has been exercised up to the delivery of OS/7's login screen over RDP from a real RDP client;
the per-user sign-in that follows is owed (O-R2).** On a GUI bench (GDM, swtpm TPM2) FreeRDP
3.31 passed CredSSP with a shared credential, the daemon started the handover, and the
OS/7-branded greeter and its per-user password prompt reached the client over RDP and were
photographed (M-R29, M-R33, M-R14); the client's real IP arrived at PAM on the greeter path as
`rhost` (M-R34); mstsc from the Windows host reached the same daemon (M-R30).

**v1 OF THE CMDLET SURFACE IS BUILT, AND IT HAS RUN ON A MACHINE (2026-09-07).**
`powershell/OS7/OS7.RemoteDesktop.ps1` implements the eight v1 verbs of §5;
`installer/testing/check-remotedesktop-logic.py` holds the decisions with no daemon and no VM.
On the GUI bench, `Enable-OS7RemoteDesktop -AllowAnySource` issued a hostname-SAN certificate,
generated a machine credential it did not print, brought the daemon up listening on 3389, and
`Test-OS7RemoteDesktop` returned every check green — including the two that only a connection can
answer: the daemon serves the certificate on disk, and a client offering anything but NLA is
refused (`RDP_NEG_FAILURE 5`). A real RDP client (FreeRDP 3.31) then authenticated with the
generated credential, and was refused with a wrong one. `Disable-` returned the machine to nothing
listening, unit disabled, `enabled=false`. **What is still NOT built:** the group, the PAM
profile and the session verbs — they are deferred behind the owed measurements, not forgotten
(§5, O-R2/O-R3). **The feature is
amd64-GUI only:** gnome-remote-desktop ships only on the amd64 GUI product, transitively behind
`ubuntu-desktop-minimal`; the headless installer purges it (M-R19) and arm64 never had it. There
the remote path stays `Enable-OS7Remoting` (ssh / `Enter-PSSession`), and `Get-OS7RemoteDesktop`
reports `Supported=$false` rather than pretend.

**The whole path is proven since 2026-09-07, and v1 still has real security gaps.** A local
account signs in over RDP and reaches the OS/7 desktop; `loginctl` records a remote wayland
user session carrying the client's address (M-R50/M-R51). The claim that this did not work was
withdrawn — it was a keyboard-layout fault in the test harness, not a defect (RL14, BUILD-NOTES #128).
And a deployer must weigh (see R3) no per-user allow-list, no lockout at either stage, no
attributable log for a refused NLA attempt, and one shared machine secret that today rests in
plaintext (RL1/RL4/RL5/RL8). The plan makes an operator source scope a precondition of exposing
the port (R9) because of this, and the feature is not shippable while the lockout stays deferred
(R10, O-R3/O-R4).

---

## 2. What was measured

Taken 2026-09-05 on `os7img:175` (systemd as PID 1, no GDM/TPM/Wayland) and on a booted GUI bench
(`OS7-1.0.0.163-amd64`, GDM, swtpm TPM2, KVM-in-Docker); package presence cross-checked against the
build's `OS7-1.0.0.175-amd64.packages.manifest` (#93). The `M-R` numbers are the dossier's, verbatim.

| # | Fact | How |
|---|---|---|
| M-R1/M-R2 | `grdctl --system rdp enable` writes `grd.conf` (`[RDP] enabled=true`, 0664 grd:grd), `systemctl enable`s the unit **and** starts it; `rdp disable` mirrors it (`enabled=false`, keeping `tls-cert=`/`tls-key=`), nothing listens | ls, cat, systemctl, journal |
| M-R3/M-R15 | `set-tls-cert`/`set-tls-key` store **paths**, not copies; `status` prints the SHA-256 fingerprint lowercase colon-separated = `openssl x509 -fingerprint -sha256`. Key `root:gnome-remote-desktop 0640` accepted. TLS 1.3, `TLS_AES_256_GCM_SHA384`; served leaf byte-identical (SHA-256) to the file | cat, grdctl, openssl, python ssl |
| M-R4/M-R5/M-R17 | **Without a certificate** the daemon is `active/running` but does **not** listen (P6 exactly). **With a cert but no credential** it listens on `*:3389` (IPv4+IPv6) and **resets** every connection (`Credentials are not set, denying client`), no client IP in the line. `set-port 3390` → listens on `*:3390`; no negotiate-port key (sourced) | ss, X.224 probe, journal |
| M-R7 | `set-auth-methods kerberos` → **`Kerberos not supported in the system daemon`**; auth stays `credentials` | grdctl |
| M-R8/M-R13 | `grdctl --system status` unprivileged fails on polkit (`auth_admin`); root passes (cmdlets run elevated). Every grdctl call without a TPM prints a TPM-fallback line on **stderr** — a parser reads stdout only | runuser, observed |
| M-R9/M-R11 | Shipped README: remote login is **two-stage** — a system-wide password grants the graphical login screen, then the user signs in with their own credentials (so the RDP username/password is a **shared, machine-wide** secret); the daemon drives GDM's `RemoteDisplayFactory.CreateRemoteDisplay`, passing a hostname to PAM (the RDP value is M-R34) | zcat README, strings |
| M-R14 | **The system daemon requires NLA (CredSSP, HYBRID).** Cert+credential → `RDP_NEG_RSP HYBRID`; TLS-only/RDSTLS-only/HYBRID_EX-only/standard all get `RDP_NEG_FAILURE HYBRID_REQUIRED_BY_SERVER`. A non-NLA client cannot connect | X.224 probe, 8 flag sets |
| M-R16 | A **refused** connection leaves **no client address** in the daemon journal (`_SYSTEMD_UNIT=gnome-remote-desktop.service`) | journalctl -o json |
| M-R18 | The shipped unit has **no sandboxing** (`ProtectSystem=no`, `NoNewPrivileges=no`, full caps); not ordered `After=gdm.service` (waits for GDM's bus name internally) | systemctl show |
| M-R19 | **Headless amd64 removes the daemon with the desktop** (`SystemSteps.cs` purges the GNOME stack then autoremoves). No GDM, no daemon — same as arm64 | grep SystemSteps.cs |
| M-R20 | PAM modules `pam_faillock`/`pam_access`/`pam_succeed_if`/`pam_listfile` present; **no `faillock` profile; `faillock.conf`/`access.conf` empty**. The admin group is **`sudo`** (no `os7-admins` exists); grd gid 979 | ls, cat, getent |
| M-R21/M-R22 | Neither `winpr-makecert` nor `certtool` is on the image; **`openssl` is**. ufw profiles shipped are `cups`/`openssh-server`/`wsdd`; ufw is **disabled** | which, ls, cat |
| M-R6/M-R24 | `set-credentials` stores the pair in **plaintext** `credentials.ini` (0600 grd) under `/var/lib/gnome-remote-desktop/.local/share/…` (a positional password is visible in `ps`; the README documents a stdin form). **On the real machine WITH a TPM it still falls back to plaintext**: `/dev/tpmrm0` is `tss:tss`, the service user is **not in group `tss`**. Candidate fix: add grd to `tss` (owed) | find, cat, stat, id |
| M-R25 | **`grdctl` exits 0 when it did nothing.** Unelevated/no-TTY: `set-*`/`enable` all rc=0, nothing written or started. The README stdin form left the username **empty** yet rc=0; the two-argument form worked. A cmdlet must never trust grdctl's exit code | rc capture, status |
| M-R26 | On the booted machine, elevated, `set-tls-cert`+`set-tls-key`+`set-credentials`+`enable` produced correct grd.conf, `active/running`, `*:3389`. Cert/key at `/etc/os7/remote-desktop/`, key `root:gnome-remote-desktop 0640`, cert 0644, both accepted | guest-setup over ssh |
| M-R28 | **The daemon reads the credential at start** and ignores a later `set-credentials` — mstsc then gets error `0x904`; a `systemctl restart` fixes it. So `Enable-` order is cert→key→credential→enable, and a credential change must restart the unit (dropping live sessions) | journal, mstsc dialog |
| M-R29/M-R32 | **NLA works from FreeRDP 3.31 (`xfreerdp3 /auth-only`).** Right password → server begins the handover; wrong → `SEC_E_MESSAGE_ALTERED` / `ERRCONNECT_LOGON_FAILURE`, **neither line carries the client IP**. The server closes a client not advertising RDPGFX (mstsc always does; very old/minimal clients cannot connect) | xfreerdp3, journal |
| M-R23/M-R30/M-R31 | The bench host is Windows 11 with `mstsc.exe` but publishes only qmp/serial/ssh — an RDP test needs a **fourth port kind** in `os7lab.py`. **mstsc cannot be driven headlessly** (`CredentialUIBroker` refuses UIA/SendKeys) — FreeRDP is the harness oracle, mstsc the manual acceptance test. The Windows→guest path works via QMP `hostfwd_add` + a relay; **host 3389 cannot be bound**, so use another host port and `mstsc /v:127.0.0.1:<port>` | ls, UIA dump, qmp, docker -p |
| M-R33 | **The OS/7 branded login screen is delivered over RDP — photographed.** After NLA the daemon starts the handover and the client is shown the OS/7 greeter and a per-user password prompt | xfreerdp3 /gfx under Xvfb, screenshots |
| M-R34 | **PAM on the remote path receives the client's real IP as `rhost`** (`gdm-authd … rhost=172.17.0.5`). `gdm-authd` is tried **first** and **fails** (C8a); the **fall-through to `gdm-password`/`pam_unix` for a local account over RDP was not completed** — so the only line captured was a *failed* attempt; the exact service and fall-through for a completed local login are owed (O-R2) | journal, loginctl |
| M-R35/M-R36 | `loginctl` marks the remote greeter `Remote=yes` but `RemoteHost=0.0.0.0`, `Service=gdm-launch-environment`; the local seat0 greeter is untouched. Each connection spins a **new** greeter via `RemoteDisplayFactory`; they accumulate. Attaching to an existing *local user* session is unmeasured | loginctl, journal |

### What the sources say, and what has NOT been measured here

From upstream gnome-remote-desktop / GDM sources, the shipped README/NEWS, and Launchpad — read,
not run; marked by confidence and attributed rather than stated as fact.

| Claim | Confidence | Owed / cross-check |
|---|---|---|
| The units are installed `--no-enable` (Ubuntu packaging), so `gnome-remote-desktop.service` is disabled on a fresh image; the daemon reads grd.conf from three locations in order: default → `/etc/gnome-remote-desktop/grd.conf` (CUSTOM, grdctl writes here) → a **local-state** file under `/var/lib/gnome-remote-desktop/.local/share/` (no caller found for the local-state setter) — upstream | sourced | default-off O-R14; local-state override O-R17 |
| No grd daemon generates a certificate; GNOME Settings issues `C=US,CN=GNOME`, RSA-4096, no SAN, ~2 years (mstsc warns "name … is GNOME") and stores it under `/var/lib/…/certificates/` — upstream `cc-tls-certificate.c` | sourced | on the image, only that openssl exists (M-R21); Settings' cert path is O-R17 |
| `grdctl rdp enable` toggles the unit **first** then sets `enabled=true`; the listener starts only when `enabled=true` AND cert+key both load; the shared credential is one NTLM SAM entry, the user's account never seen by the system daemon; with a TPM it seals to PCRs 0–3, else plaintext `credentials.ini` — upstream | sourced | matches M-R1/M-R4/M-R11; TPM path **blocked** on OS/7 (M-R24), `tss` fix O-R1 |
| Windows matches the cert name on the **SAN**, not the CN; an RDP listener cert's EKU is Server Authentication / Remote Desktop Authentication (1.3.6.1.4.1.311.54.1.2) — Microsoft docs | sourced | mstsc wording is O-R9 |
| Kerberos remote login (greeter bypassed) arrives in g-r-d **51.x**, not 50.2 — upstream NEWS/MRs | sourced | 50.2 refusal measured (M-R7) |
| GDM sets `PAM_RHOST` on remote displays; the user login uses `gdm-password` — the **same** stack a console login uses, only `PAM_RHOST` (set for remote, empty for console) tells them apart; `pam_access` `LOCAL` **blocks** the remote greeter; `pam_succeed_if` can express "remote AND ingroup"; the greeter's `gdm-launch-environment` phase must be **exempted** or `CreateRemoteDisplay` yields a blank session — Linux-PAM/GDM sources | sourced/inferred | rendered rule + local fall-through: O-R2/O-R3/O-R18 |
| Sessions persistent since GNOME 47 (disconnect keeps, reconnect resumes, no idle/disconnect time limit); a user **cannot hold a local and a remote session at once** — gnome-shell offers to force-kill the conflicting one, losing its state (SUSE part 3, GDM !233, gnome-shell !3134); mstsc without `use redirection server name:i:1` shows a "connection is insecure" dialog | sourced | unverified on OS/7 (O-R8, O-R9) |
| Redirection in 50.2: Opus **audio out** works; **clipboard** text+files via FUSE (AppArmor-dependent, **broken for domain users**); **drive** absent; **camera** since 50.beta; no per-redirection keys. **AD/SSSD domain users' remote sessions crash on 26.04** — upstream NEWS, LP #2103889/#2150612/#2163159 | sourced | none configurable/unverified; RL7 |
| The only rate control is a per-peer throttler (CVE-2025-5024, 5 conns/peer, 10 attempts/s), **not** a lockout — `grd-throttler.c` | sourced | present in 50.2; spoofable across source IPs |
| `gnome-classic.desktop` carries `X-GDM-CanRunHeadless=true` (needed for a remote wayland session); g-s-d starts the handover only when logind says remote (a NetworkManager "OFFLINE" once suppressed it); macOS/iOS "Windows App" failed the handover on earlier g-r-d — upstream, LP #2141992, #215 | sourced | ISO/networkd O-R11/O-R12; client compat RL11 |

---

## 3. The mechanism, and why

### R1 — the gnome-remote-desktop system daemon in "remote login" mode; not xrdp, VNC or per-user sharing. Proposed 2026-09-06.

The amd64 image already carries `gnome-remote-desktop` 50.2, `libfreerdp-server3`, PipeWire and a
`gdm3` with `GdmRemoteDisplayFactory` (dossier §2); P4 forbids rebuilding it. The sessions are
**Wayland-only** (no `/usr/share/xsessions`, no `xserver-xorg-core`), which rejects the
alternatives: **xrdp** is X11 (a second desktop stack and a login path outside GDM's PAM), **VNC**
is not RDP and has no NLA, and **grd's per-user "Desktop Sharing"** needs a console user and
defaults `view-only`. The **system** daemon instead asks GDM for a fresh headless greeter per
connection (M-R9, M-R33, M-R36), needs nobody at the console, and speaks NLA the way mstsc expects
(M-R14) — the Windows "Remote Desktop for administration" model. OS/7 adopts it unchanged and adds
policy on top, never a second RDP stack.

### R2 — OS/7 drives `grdctl --system` for state and verifies afterward; it does not hand-write grd.conf, and it knows there is a second writer. Proposed 2026-09-06.

The daemon reads one GKeyFile group `[RDP]`, keys
`enabled/tls-cert/tls-key/port/auth-methods/kerberos-keytab` (M-R1/M-R3/M-R17), from three
locations in order (sourced): the shipped `/usr/share` default, `/etc/gnome-remote-desktop/grd.conf`
(where grdctl writes), then a **local-state** `grd.conf` under `/var/lib/gnome-remote-desktop/…`.
**Driving `grdctl --system`** (`set-tls-cert`, `set-tls-key`, `set-credentials`, `rdp
enable`/`disable`) in the order M-R28 forces, then **verifying from the thing itself** (P5), is
the path measured to work when elevated (M-R26 on the machine, M-R1 in the container); grdctl's
only sharp edge is that it **exits 0 having done nothing** unelevated / with no TTY (M-R25) — but
the cmdlets run elevated (M-R8), and the fix is to read the result back, not to abandon grdctl.
**Hand-writing grd.conf** revives #64/#66 (a paraphrased config is a listener on nothing) and is
unmeasured, so OS/7 drives grdctl.

**A second writer exists, and Get- sees it.** GNOME Settings' "Remote Login" panel writes the same
effective config through the configuration daemon, and its `ImportCertificate` stores a cert under
`/var/lib/…/certificates/` (sourced) — a *different* path than OS/7's `/etc/os7/remote-desktop/`.
Because `Get-` reads `grdctl --system status`, which reflects the **merged/effective** config, it
*does* see a Settings-made change — a point in OS/7's favour, and why `Get-` never parses `/etc`
alone. `New-`/`Set-` always author `/etc` + `/etc/os7` and re-point `grdctl set-tls-cert/-key`, so
OS/7's cert wins. Whether a Settings-written **local-state** `grd.conf` can override `/etc` (setter
exists, no caller found) is **owed (O-R17)**; the manual points a remote admin at the cmdlets, not
the Settings panel, which cannot even Unlock from inside a remote session (sourced, LP #2140528).

One honesty note: `grdctl rdp enable` does the unit `EnableUnitFiles`+`StartUnit` itself (matching
M-R1) — the one place a state change reaches systemd through the vendor tool, which does not breach
P2-systemd (`grdctl` is on no token list). The `Systemd` module still does the `ActiveState`/journal
reads and the **restart** on a credential/cert change grdctl has no verb for (M-R28). The "diff
grd.conf against grdctl's output" idea is kept only as a **Tier-1 test assertion**.

---

## 4. The security model

### R3 — default OFF, and an honest account of what v1 does and does not defend. Proposed 2026-09-06.

A fresh machine ships `gnome-remote-desktop.service` present but **not enabled** (sourced: Ubuntu
installs it `--no-enable`; asserted on the ISO by O-R14), `/etc/gnome-remote-desktop/` empty, no cert,
no credential (dossier §2) — Windows' "remote connections aren't allowed" and CISA CM0042. Enabling
is a deliberate act; `Disable-` returns the machine there.

**Two-stage authentication, as measured.** There are **two** logins. **(1) NLA/CredSSP at the
door**, against a single machine-wide RDP credential checked before any screen exists: the daemon
*requires* NLA (`HYBRID`), every non-NLA offer is refused (`HYBRID_REQUIRED_BY_SERVER`, M-R14),
and with no credential it listens and resets everyone (M-R5) — CIS's
`UserAuthentication=1`/`SecurityLayer=2` as a hard default, with a *machine* secret where Windows
has the *user's* account. **(2) The personal login at the GDM greeter, shown over RDP**: after NLA
the client is redirected into a headless greeter (M-R33); PAM there sees `rhost=<client-ip>` (M-R34).

**The threat framing, and where it breaks in v1.** The shared NLA secret is *meant* to be a
**low-value gateway token** whose compromise buys only the right to be shown the login screen —
but that is only as good as the second factor and the controls before the first, and **v1 ships
neither.** v1 has no per-user allow-list (any local account past the secret reaches the greeter,
RL8), no lockout on the shared secret (RL4), no faillock on the greeter login (deferred,
R10/O-R3/O-R4), and no source IP for a refused NLA attempt (M-R16, RL5); the only rate control is a
per-peer throttler (sourced), spoofable across source IPs. So an un-scoped v1 listener is a
remotely reachable, essentially unthrottled, unattributable path to online password-guessing
against privileged local accounts (`os7admin`), gated by one shared, plaintext (RL1), never-rotated
secret with no lockout. **This is why `Enable-` makes a source scope a precondition (R9), and why
the feature is not shippable until the greeter faillock (O-R3/O-R4) lands.** The gateway-token
framing becomes true only once the second-stage lockout and allow-list exist.

### R4 — the machine-wide RDP credential: OS/7 generates it, surfaces it only by a deliberate act, rotates it. Proposed 2026-09-06.

Windows has no equivalent, so it gets its own name: the **machine RDP credential**, username fixed to
**`os7-rdp`** (*maschinenweite Remotedesktop-Anmeldeinformation*). `Enable-OS7RemoteDesktop` generates
a high-entropy random secret (`RandomNumberGenerator`) and sets it through `grdctl --system rdp
set-credentials`.

**How the secret is set is an owed measurement, not a decision (O-R13).** The P7-safe stdin form is
the one M-R25 measured *silently failing* (rc=0, username empty); the only form measured to work put
the password on argv (M-R6). So an invocation that sets username+password reliably **and** keeps the
secret off argv (username as an argument with password on stdin, an expect-style feed, or writing
`credentials.ini` 0600-before-content and restarting) is **owed** before locking R4. `Enable-`
**reads the state back** and fails if it did not take, without capturing the plaintext (O-R13),
never `status --show-credentials` in the normal path.

**The secret reaches the operator only by a deliberate act, never on Enable-'s output.** In tension
with P7, the credential must be typeable into mstsc once. So `Enable-`'s output — on **any** stream,
interactive or not — **never contains the secret**; it is surfaced only by
`Set-OS7RemoteDesktopCredential -Reveal` (optionally `-Rotate`), returning a
`[pscredential]`/`[securestring]`. Unattended (`-Confirm:$false`, R16) never reveals it — the key is
fetched out-of-band by a human. OS/7 never auto-prints, logs or serialises it; `Get-` reports only
`CredentialSet=$true`. Rotation restarts the unit (M-R28) and says so (drops live connections).

**RL1 — the credential rests in plaintext today.** Even with a TPM the daemon falls back to
`/var/lib/gnome-remote-desktop/.local/share/…/credentials.ini` (0600, grd), because the service
user is not in group `tss` and cannot open `/dev/tpmrm0` (M-R24). The candidate fix (a sysusers/udev
drop-in adding grd to `tss`) is **owed (O-R1)** and not unqualified: a working TPM seals to PCRs 0–3
(sourced); a firmware or bootloader change can make such a seal unrecoverable (sourced), so whether
`Update-OS7` breaks it is owed (O-R1) — the PCR problem the S6 spike solves for LUKS. Any sealing
must reseal across `Update-OS7` like S6, or re-set the credential on the new BE's first boot (open
question 4). The plan states plaintext-at-rest and claims no TPM sealing.

### R5 — who may log in is a group, enforced ONLY on the remote GDM PAM path; the cmdlets are deferred. Proposed 2026-09-06.

Windows grants the RDP logon right to *Administrators* plus *Remote Desktop Users* (empty by
default). OS/7's equivalent is the group **`os7-remotedesktop`** (DE: *Remotedesktopbenutzer*),
shipped **empty**, plus the administrators — the admin group is **`sudo`** (M-R20); no
`os7-admins` group appears in the measured group list. Enforcement lives at **GDM's PAM path for remote
displays**, because M-R34 proved PAM on the remote path receives the client IP as `rhost`; a console login
carries none (sourced, GDM sources) — so PAM tells the remote greeter from console and ssh (by `PAM_SERVICE` and `rhost`).

The intended rule (`pam_succeed_if`; `pam_access`'s `LOCAL` match would block the remote greeter
— sourced) admits a remote-greeter login only when the account is in `os7-remotedesktop` or
`sudo`, fires **only** on the remote path (a non-empty `rhost`), and **exempts** the greeter's
own `gdm-launch-environment` account phase — a rule that hits it makes `CreateRemoteDisplay`
succeed with a **blank, login-less** session (sourced; the single most important correctness catch
here). The deferred design also owes a **deny path** (`pam_succeed_if 'not ingroup sudo'` or a deny
group) so a hardened host can forbid *admin* RDP, which CISA CM0042 recommends and Windows expresses
as "Deny log on through RDS" — v1 has neither (RL8). **The rendered lines are a proposal, not copyable
text**: the PAM service and whether a **local** account falls through `gdm-authd` to `gdm-password`/
`pam_unix` over RDP is **O-R2** (M-R34 saw `gdm-authd` fail at C8a and not complete the local login),
the profile's order **O-R3**.

**The most important operability property — that this can never lock the operator out — is
DESIGNED, not yet measured.** The group and lockout attach only on the remote path (non-empty
`rhost`), so a broken allow-list *should* leave console and ssh untouched (safe failure). But the
user login over RDP uses `gdm-password`, the **same** stack a console user-login uses (sourced);
only the `rhost` guard separates them, and whether it truly isolates remote from console is
O-R2/O-R3. So before any PAM profile ships, §9 adds a gating **control**: with an account
locked/denied over RDP it must still authenticate at the physical console and over ssh (O-R18).
Because enforcement is owed, the cmdlets **`Add-/Remove-/Get-OS7RemoteDesktopUser`** and the PAM
profile are **deferred** — a built `Add-OS7RemoteDesktopUser` would imply "this user can now
connect," the unproven claim — so v1 has no per-user allow-list (RL8).

### R6 — Kerberos at the door is impossible here; a "cannot", not a roadmap item. Proposed 2026-09-06.

`grdctl --system rdp set-auth-methods kerberos` → `Kerberos not supported in the system daemon`
(M-R7). Kerberos remote login (AD identity checked at connect, greeter bypassed) arrives only in
gnome-remote-desktop **51.x** (sourced), which Ubuntu 26.04 lacks — so "AD SSO at the door" is
unavailable **regardless of AD Stage 2** (AL5), and the domain-user session additionally crashes on
26.04 (sourced, LP #2150612). Restricted Admin and Remote Credential Guard have no Linux analogue.
All are §10 "cannot" rows.

### R7 — the TLS certificate: self-signed hostname-SAN by default, CA-issued by replacement, validated by the loader that reads it. Proposed 2026-09-06.

No grd daemon generates a certificate (sourced); GNOME Settings would, with `CN=GNOME` and no SAN
(a name-mismatch warning in mstsc). OS/7 does better, on first enable, with the only tool on the
image (M-R21), generating under a restrictive umask so the key is **never** group/other-readable at
any instant (P7, #117 — on the Windows authoring host every path presents as 0777):

```
( umask 077
  openssl req -x509 -newkey rsa:4096 -noenc -keyout tls.key -out tls.crt \
    -days 825 -subj "/CN=<fqdn>" \
    -addext "subjectAltName=DNS:<fqdn>,DNS:<host>" \
    -addext "extendedKeyUsage=serverAuth" )
```

A **SAN** is required because Windows matches on the SAN, not the CN (sourced); 825 days avoids a
yearly re-enable; RSA-4096 matches GNOME Settings' peer strength; a `serverAuth` EKU meets the
enterprise/mstsc expectation the CA path names. The key is created 0600 by the `umask 077` (never
wider), then owned `root:gnome-remote-desktop` **0640**, cert 0644 — the ownership the daemon was
measured to accept (M-R26); `set-tls-cert`/`set-tls-key` store only the path (M-R3). Three granular
verbs mirror Windows' `Get-`/`Set-RDCertificate`: **`New-`** (self-signed default), **`Get-`** (the
fingerprint as `grdctl status` prints it — SHA-256 lowercase colon-separated, M-R3/M-R15 — **and**
the SHA-1 the Windows certificate dialog is expected to show (inferred, O-R9)), and **`Set-…Certificate -CertPath -KeyPath`** (a CA-issued PEM
pair; EKU `1.3.6.1.4.1.311.54.1.2` or `serverAuth`, SAN=FQDN). The PEM pair is the Linux idiom
(`grdctl set-tls-cert/set-tls-key` take paths); a Windows admin's PFX habit has no direct verb (a
future `-PfxPath`/`-Password` could split it — noted, not built). Validation follows #111:
`Enable-` opens a TLS connection to `127.0.0.1:3389` and asserts the served leaf's SHA-256 equals
the file's (M-R15), never trusting `openssl` alone. The self-signed default still warns "identity
cannot be verified" until the issuing CA is trusted on the clients (Intune can push it).

### R8 — where the key lives, relative to the boot environment. Proposed 2026-09-06.

`/etc/os7/remote-desktop/` is inside the boot environment, so `Restore-OS7` restores the key/cert at
the snapshot — correct for a self-signed key nobody else trusts. A **CA-issued** key clients have
pinned is D10's "state something outside this machine also believes," the shape of `/etc/krb5.keytab`
(AD-PLAN AL2). It opens no new question: it **joins DECISIONS open question 9**, and `Test-` warns
when the served fingerprint differs from one recorded outside the BE
(`/var/lib/os7/remote-desktop/fingerprint`, `rpool/DATA`, subject to O-R5).

### R9 — 3389/tcp on both families; exposure is scoped by the operator, and the firewall question is not decided here. Proposed 2026-09-06.

The daemon binds `*:3389` deterministically on **IPv4 and IPv6** (M-R5); it has no negotiate-port
key (sourced; the property default is FALSE, inferred), so the listener is deterministic on 3389 or the configured
`port=` — good for a firewall rule (grdctl's port-negotiation verbs apply to the per-user daemon,
not `--system`). It has **no bind-address key**, so OS/7 cannot scope the listener at the daemon —
only a firewall can. But **no host firewall is active on OS/7** and no firewall cmdlets exist (open
question 1); this feature does not decide that product question.

Because an unscoped listener is the exposure R3 describes, **`Enable-` makes source scope a
precondition.** It takes `-AllowFrom <CIDR[]>`; with a firewall active it installs and enables the
source-scoped rule (both families) for those CIDRs — that direct `ufw` handling is provisional, and once the Tier-2 `Get-/New-OS7FirewallRule` cmdlets exist `Enable-` routes through them rather than calling `ufw`. With no firewall active (the OS/7 default)
`-AllowFrom` cannot be enforced, so `Enable-` **refuses** unless the operator passes
`-AllowAnySource` — an explicit acknowledgement that 3389 will be reachable from everything the
network allows — and then prints the exact rule to apply by hand: `ufw allow from <cidr> to any
port 3389 proto tcp` (and its v6 form), never `ufw allow 3389` to the world (CISA CM0042). OS/7
still does **not** run `ufw enable` or decide the product question. The ufw **application** profile
`os7-remote-desktop` (`ports=3389/tcp`, the stable non-localized name, M-R22) is an **inert** static
file shipped by the package (§13) — it does not enable ufw and does not decide open question 1.
`FirewallState` reports `Inactive`; there is no Domain/Private/Public analogue on Linux.

### R10 — brute force: v1 ships NO lockout at either stage; the 10/10/10 faillock is owed and gates the feature. Proposed 2026-09-06.

`faillock.conf` is empty and there is no `faillock` pam-config (M-R20), and **v1 ships neither** —
diverging from the Windows 11 default this section would otherwise cite (10 attempts / 10-min
lockout / 10-min reset, `local_users_only` so AD accounts lock on the DC, KB5020282). The shared
NLA secret has no lockout at all (RL4); the daemon's per-peer throttler (CVE-2025-5024, sourced)
is DoS mitigation, spoofable across source IPs, not a lockout. The owed faillock profile lives on
the remote greeter path only, scoped so a lockout never reaches the console (safe failure, R5); it
is **part of R5's `pam-auth-update` deferral (O-R3/O-R4)** and is a **gate before `Enable-` is
offered** as a shippable feature. Until it lands, the port's only defence is credential strength
(R4) and the operator-supplied source scope (R9). This gap is stated as RL4, not implied inside a
decision that reads as shipped.

### R11 — audit: for v1 (local accounts) attribution is unproven; who was refused is not answerable at all. Proposed 2026-09-06.

A **refused** connection leaves **no client address** anywhere OS/7 can read — the daemon journal
carries FreeRDP's failure lines with no peer IP (M-R16, M-R29) and `loginctl` shows
`RemoteHost=0.0.0.0` (M-R35). So "who was refused at NLA, from where" — the brute-force case — is
**not** answerable; there is **no 4625-equivalent** for it (RL5). For a *per-user* attempt PAM
carries `rhost=<ip>`, but M-R34 measured that only on a **failed** `gdm-authd` attempt; whether a
**completed local** login over RDP — the only kind that works in v1 — reaches `pam_unix` and emits
an rhost-bearing success line is **unproven pending O-R2**. So the 4624 (success) equivalent is
owed, the 4625 (failure) equivalent is measured only for the gdm-authd path, and the refused case
has no evidence. Completing O-R2 (a real login, then `Get-OS7Log -Unit …`) gates any audit claim.
Whether a peer IP is recoverable from daemon debug logging or nft counters is O-R6.

### R12 — never to the internet; the enterprise path, honestly. Proposed 2026-09-06.

3389 stays on the LAN. There is no RD Gateway analogue; the honest routes are a VPN, **Entra
Private Access** (tunnels RDP to an on-prem host, no exposed port), **Azure Bastion** (Azure VMs
only), or **Arc SSH** — thin, since the relay is one port (22) and `az ssh arc --rdp` is documented
only for **Windows clients** (whether it works against a Linux target is unverified), so for a Linux
Arc server the channel is ssh with a local `-L 3389` forward (no OS/7 machine has been Arc-enrolled).

---

## 5. The PowerShell surface

### R13 — the noun is `RemoteDesktop`; Windows names are not reused (P1). Proposed 2026-09-06.

Windows has no `Enable-RemoteDesktop` cmdlet — admins set `fDenyTSConnections`,
`Enable-NetFirewallRule` and `Add-LocalGroupMember` separately — so P1 leaves the name free (Windows
names appear only in an opt-in `OS7.Compat.Windows`). Cmdlets follow the `Enable-OS7Remoting`
skeleton: `[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]`, one gate, validate with
the parser that will read it, return `Get-` at the end.

**v1 — BUILT 2026-09-07 (`powershell/OS7/OS7.RemoteDesktop.ps1`), and exercised against the real daemon on the GUI bench:**

| Cmdlet | Does | Key output / behaviour |
|---|---|---|
| `Get-OS7RemoteDesktop` | asks daemon, unit, socket | `Supported`, `Enabled` (grd.conf; configured), `Running` (unit `ActiveState`), `Listening` (3389 socket, **both families** — M-R5 — not implied by `Running`, M-R4), `CertificatePresent`, `FingerprintSha256`/`Sha1`, `CredentialSet`, `AuthMethods`, `Port`, `FirewallState`, `Detail`, `*Reason`; a field not askable is **`$null`, never `$false`**; reads `grdctl status` stdout only (M-R13) |
| `Enable-OS7RemoteDesktop` | cert→key→credential→enable, one gate; requires `-AllowFrom`/`-AllowAnySource` (R9) | returns `Get-`; **never emits the credential** on any stream (R4/R16) |
| `Disable-OS7RemoteDesktop` | `enabled=false`, stops+disables the unit; **clears the credential** by default (`-KeepCredential` retains) | leaves cert/key/group in place; **drops live client connections** (divergence, below); returns `Get-` |
| `Set-OS7RemoteDesktopCredential` | `-Rotate` (new secret) and/or `-Reveal` (deliberate surfacing); restarts the unit on rotate (M-R28) | `-Reveal` returns the credential once; else nothing secret |
| `New-OS7RemoteDesktopCertificate` | self-signed, hostname SAN, serverAuth EKU, umask-safe key | returns `Get-OS7RemoteDesktopCertificate` |
| `Get-OS7RemoteDesktopCertificate` | reads the served + stored cert | SHA-256 and SHA-1, subject, SAN, notAfter |
| `Set-OS7RemoteDesktopCertificate` | `-CertPath -KeyPath`, re-owns, re-reads served leaf (#111) | returns `Get-` |
| `Test-OS7RemoteDesktop` | a **local** health oracle | boolean per check, `$null` for "could not ask" |

**Disable- diverges from Windows, stated plainly.** Windows' disable keeps existing connections and
refuses new ones (sourced); OS/7's `Disable-` sets `enabled=false` and stops the unit (M-R2),
dropping the client transport — there is no gentler grdctl path, so this is a named limitation, not
a `-Force` toggle (whether logged-in *user* sessions survive is O-R7). `Disable-` also **clears the
machine credential** by default so turning RDP off closes the door (`-KeepCredential` retains it);
until cleared the plaintext secret persists across rollback and possibly into backups (RL13).

**Deferred, with reasons:** `Add-/Remove-/Get-OS7RemoteDesktopUser` — blocked on the enforcement
measurement O-R2/O-R3 (R5); relates to the planned Tier-2 `Get-OS7User`/`Get-OS7Administrator`.
`Get-/Disconnect-OS7RemoteDesktopSession` — needs a logind verb the `Systemd` module lacks
(`loginctl` is a P2-systemd token; §6); the Windows split (`Disconnect-RDUser` keeps apps,
`Invoke-RDUserLogoff` ends them) maps to `Disconnect-`/future `Stop-OS7RemoteDesktopSession`.
`Import-OS7RemoteDesktopCertificate` from an enterprise CA — Tier-2 Certificates, not started.

**How `Enable-` orders and answers.** One gate (#115), order **cert → key → credential → enable**
(M-R28/M-R4), generating a hostname cert and random credential if none exist, validating the cert
with the loader that reads it (#111), setting state through `grdctl` (R2), then **answering from the
thing itself** (P5) — `grdctl status`, `ActiveState`, a 3389 socket probe, never grdctl's exit code
(M-R25). It is **idempotent** (required for the Intune cadence, §8). **`Test-`** is a local oracle
(the real `xfreerdp3 /auth-only` oracle, M-R29, is off-box): cert present/owned/unexpired, SAN
matches, served fingerprint equals the file, socket listening, credential set, NLA-only, ufw profile
present. It does not claim to have proven a remote login (§9).

### Windows → OS/7 (for Appendix C)

| Windows | OS/7 | Note |
|---|---|---|
| Settings → *Enable Remote Desktop* / `fDenyTSConnections=0` | `Enable-OS7RemoteDesktop -AllowFrom …` | one switch does service + cert + credential; source scope required |
| the credentials typed in mstsc | **the machine RDP credential** (`os7-rdp`), then your own account at the OS/7 login screen | **two logins** — the unfamiliar part |
| *Remote Desktop Users* (`Add-LocalGroupMember`) | group `os7-remotedesktop` (*Remotedesktopbenutzer*) via `Add-OS7RemoteDesktopUser` *(deferred)* | enforced at the GDM login, not the port |
| Administrators auto-allowed; *Deny log on through RDS* | `sudo` members allowed; deny path *(deferred, R5)* | v1 cannot exclude admins |
| NLA (`UserAuthentication=1`) | mandatory, not configurable (`HYBRID_REQUIRED_BY_SERVER`, M-R14) | cannot be disabled |
| self-signed cert → "identity cannot be verified"; `SSLCertificateSHA1Hash` | `New-OS7RemoteDesktopCertificate` (hostname SAN); `Set-` for a CA cert | same warning until the CA is trusted |
| `Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'` | `ufw allow from <cidr> to any port 3389/tcp` (printed; no firewall active) | open question 1 |
| `qwinsta` / `quser` | `Get-OS7RemoteDesktopSession` *(deferred)* | needs the Systemd session layer |
| `tsdiscon` / `logoff` | `Disconnect-`/`Stop-OS7RemoteDesktopSession` *(deferred)* | persistent since GNOME 47 (sourced) |
| Restricted Admin / Remote Credential Guard, Kerberos SSO at the door | — | no Linux analogue; daemon refuses Kerberos (M-R7) |

### Examples an admin types

```powershell
Enable-OS7RemoteDesktop -AllowFrom 10.0.0.0/24   # turns RDP on for that subnet; no secret is printed
Set-OS7RemoteDesktopCredential -Reveal            # deliberately surface the machine credential to save
Get-OS7RemoteDesktop | Format-List Enabled, Running, Listening, FingerprintSha1, FirewallState
Set-OS7RemoteDesktopCertificate -CertPath ./host.crt -KeyPath ./host.key   # then Get- shows SHA-256 + SHA-1
Set-OS7RemoteDesktopCredential -Rotate -Reveal    # rotate and surface; restarts the daemon, drops live sessions

# From Windows:  mstsc /v:os7box.corp.example — type the MACHINE credential (os7-rdp) at NLA, accept
#   the self-signed warning (compare the fingerprint, O-R9), the OS/7 login screen appears OVER RDP, sign in as
#   yourself. You cannot hold a local and a remote session at once — forcing one kills the other (§10).
```

The manual ships an `.rdp` template with `use redirection server name:i:1` so mstsc does not
raise the "insecure connection" dialog (sourced; O-R9).

---

## 6. The layer cut

### R14 — no generic module; the Remoting precedent is followed. Proposed 2026-09-06.

P2 grants a generic layer only where a subsystem has its **own vocabulary AND** the product has
policy on top. gnome-remote-desktop is one daemon, one six-key config, one tool (`grdctl`), and
nearly everything OS/7 does with it *is* policy — the credential, group, lockout, firewall stance,
cert placement. A `powershell/Grd/` would be P2 by reflex, which P2 forbids (`OS7.Remoting.ps1`'s
argument about one sshd keyword). So the code is `powershell/OS7/OS7.RemoteDesktop.ps1` alone,
driving `grdctl` through `Invoke-OS7Native` (on no token list); nothing at import scope (#82).

It **uses** the `Systemd` module for the unit `ActiveState`/journal and the restart on credential/cert
change. The gap is **sessions**: listing who is connected needs `loginctl` (a token), which `Systemd`
does not export — so a new generic **`Get-SystemdSession`** must land there **before**
`Get-OS7RemoteDesktopSession`, which is why the session verbs are deferred (§5) and `Get-SystemdSession`
is **not a v1 change** (§13). A direct `loginctl`/`busctl` here would turn `check-layering.py` red.
**No new rule** is added; baselines stay Z1 0 / P2 0 / P2-time 0 / **P2-systemd 2** / P2-directory 1.

---

## 7. Where state lives, rollback, and first boot

### R15 — config and the self-signed key inside the boot environment; the credential outside it (pending O-R5); nothing baked into the ISO. Proposed 2026-09-06.

| Path | Owner / mode | In the BE? (D10) | On rollback / `Update-OS7` |
|---|---|---|---|
| `/etc/gnome-remote-desktop/grd.conf` | grd:grd 0664 (M-R1) | **yes** | rolls back with `/etc`; a restored older BE can have RDP off, or point at a since-replaced cert |
| `/etc/os7/remote-desktop/tls.{crt,key}` | key `root:grd` 0640, cert 0644 (M-R26) | **yes** | rolls back — the machine presents the certificate it presented then |
| machine credential `credentials.ini` (or a future TPM blob) | grd 0600, `/var/lib` | **proposed: no** (`rpool/DATA`), **pending O-R5** | *if* `/var/lib/gnome-remote-desktop` is on `rpool/DATA` it survives rollback (matching D10 "state a system outside also believes" — a client may have saved it); *if* it is inside the BE it rolls back, which would break this argument — so the placement is not decided until O-R5 |
| ufw application profile `os7-remote-desktop`; PAM/faillock profile | root 0644; OS/7-owned (path per O-R3) | yes | inert until enabled (R9) / deferred (R10) |
| `/var/lib/os7/remote-desktop/fingerprint` | root 0644 | **proposed: no** (`rpool/DATA`, pending O-R5) | pin-record outliving rollback so `Test-` can warn (R8) |

Nothing carrying identity is baked into the ISO: the private key is **generated on the machine**
(umask-safe from creation), never shipped — a baked-in key gives every machine one identity (#117,
#118). A **first-boot** generator is deliberately **not** used (the SAN needs the final hostname);
`Enable-` generates on demand, and **nothing belongs in the installer** (opt-in, post-install).
`Restore-OS7` rolls `/etc` back while the credential's fate depends on O-R5, so a rolled-back
`grd.conf` may point at a since-replaced key; `Get-` reports the mismatch (P6). The whole D10
argument here is **proposed pending O-R5**, not built on an unmeasured dataset boundary.

---

## 8. Fleet path — Intune, Arc, compliance

### R16 — unattended enablement is a root bash script that calls the cmdlet non-interactively; it never emits the secret. Proposed 2026-09-06.

Intune's Linux device configuration is Bash "Platform scripts" only (Root, every 15 min); there is
**no Linux RDP setting** in any Intune catalog and — contrary to open question 1's fear — **no Linux
firewall compliance setting** either (Linux compliance is only Allowed distributions, Custom
compliance, Device encryption, Password policy), so a tenant can only *script* it: **Enable** with
`pwsh -NoProfile -c 'Enable-OS7RemoteDesktop -AllowFrom <cidr> -Confirm:$false'` (idempotent for the
15-min cadence, R13; CA certs push the same way).

**Enablement and credential delivery are separate, deliberately.** Under `-Confirm:$false` the
cmdlet **never emits the machine credential on any stream** (R4), so the secret cannot land in
Intune's captured script log ("shouldn't be used for sensitive information", sourced). Intune turns
the daemon on; the door key is set/rotated and surfaced **out-of-band** by a human running
`Set-OS7RemoteDesktopCredential -Reveal` — Intune can enable RDP but cannot hand out the key, so
the fleet story is not a dead end. **Compliance evidence** is `Get-OS7RemoteDesktop | ConvertTo-Json`
(the credential never a field, P7): a discovery script can require `Listening=true`, a non-expired
`FingerprintSha256`, or the opposite.

**Not claimed.** Entra sign-in does not work (C8a), so an Entra-account RDP logon cannot be
promised; no OS/7 machine has been Intune-, Arc-enrolled or domain-joined; `az ssh arc --rdp`
against a Linux target is unverified; the domain-user remote session crashes on 26.04 (RL7). Every
fleet sentence is a claim about code and Microsoft's docs, not about a running estate.

---

## 9. Test strategy

### R17 — three tiers, and the gate is a connection, not a file (#85). Proposed 2026-09-06.

| Tier | Harness | Proves | Measured possible? |
|---|---|---|---|
| 1 | `check-remotedesktop-logic.py` — fakes + recorded `grdctl --system status`, via `$script:OS7Grd*` seams | Enable's cert→key→credential→enable order; validate-before-write; the P6 fields; `$null` vs `$false`; the credential never reaching any stream/JSON; **the key never group/other-readable at any instant of generation** (R7); the `-AllowFrom`/`-AllowAnySource` gate; Disable- clears the credential; **the written grd.conf diffed against grdctl's** | seconds, no VM (pattern exists) |
| 2 | systemd-PID-1 container (`check-management-logic.py` pattern) | unit states; grd.conf written/removed; the socket bound **only** with a cert, on **both families** (M-R4/M-R5); X.224 offering 0x0f → `HYBRID`, other flags → `HYBRID_REQUIRED_BY_SERVER` (M-R14); the vendor-refusal control; the rendered PAM profile via `pam-auth-update --package` (O-R3) | ~1 min, no GDM — **all measured possible (§7 dossier)** |
| 2 | `check-image.py` additions against the ISO squashfs | the units; **`gnome-remote-desktop.service` NOT in `graphical.target.wants` — the falsifiable form of default-OFF (O-R14)**; polkit rules; **no pre-generated key** shipped; `gnome-classic.desktop` carries `X-GDM-CanRunHeadless=true` (O-R11) | seconds |
| 3 | GUI bench (`os7lab.py install --mode Gui`) + a FreeRDP client container | a **real connection**: `xfreerdp3 /auth-only` as the NLA oracle (right pw → handover, wrong → `SEC_E_MESSAGE_ALTERED`, M-R29); the greeter photographed under Xvfb (M-R33); a **completed** local login then `loginctl`/PAM journal over ssh (O-R2, M-R34/M-R35); 3389 via QMP `hostfwd_add` + a relay (M-R31) | minutes, from a snapshot |
| 3 | `mstsc /v:127.0.0.1:<port>` from the Windows host | operator acceptance only — mstsc cannot be driven headlessly (`CredentialUIBroker`, M-R30); host 3389 unbindable, use another port (M-R31) | manual |

**Controls (a check that cannot fail is not a check, the `check-ssh-login.py` shape):** the backend
must read **disabled before** `Enable-`, **enabled+listening after**, disabled again after
`Disable-`, and moving OS/7's `grd.conf` aside must flip the answer (#85); a **wrong** password must
fail at NLA (M-R29); once built, moving the PAM rule aside must let a non-group user reach the
greeter (the rule, not the default); and — the safe-failure control for R5 — a remote-locked/denied
account must **still authenticate at the physical console and over ssh** (O-R18). **A by-hand bench
connection is a finding, not a gate** — the gate is a `run-*.py` that restores a snapshot, enables,
connects with FreeRDP, and asserts. Gating nothing yet: O-R1, O-R2, O-R4, O-R6, O-R8, O-R13, O-R15,
O-R16, O-R17, O-R18.

---

## 10. What OS/7 deliberately does not do

| | Why |
|---|---|
| **Kerberos / AD identity at the RDP door; Restricted Admin / Remote Credential Guard** | `Kerberos not supported in the system daemon` (M-R7); remote-login Kerberos is g-r-d 51.x, not 26.04's 50.2 (sourced); AD Stage 2 never run (AL5); RA/RCG are Windows LSA features with no Linux analogue |
| **Take over the console session** | Unlike Windows, RDP never takes over the console; a user **cannot hold a local and a remote session at once**, and forcing one offers to kill the other with **data loss** (sourced; GDM !233, gnome-shell !3134). Each connection spins a new headless greeter (M-R36). OS/7-specific confirmation is O-R8 |
| **Per-redirection switches; and what actually redirects** | The system daemon exposes only `view-only` (hard-coded FALSE) and **no per-redirection keys** in grd.conf. In 50.2 (sourced): audio-out (Opus) works, clipboard text+files works via FUSE (AppArmor-dependent, broken for domain users), **drive** redirection is absent, camera exists since 50.beta; none is configurable per-connection, and none is measured on OS/7 |
| **Session time limits** | gnome-remote-desktop has no active/idle/disconnected session time limit (only a 30 s handover abort and the per-peer throttler, sourced); sessions are persistent (GNOME 47+) and end only on explicit logout — a disconnected session lives until reboot |
| **A per-user "Desktop Sharing" surface; VNC** | Desktop Sharing needs a console user (the system daemon is the admin model); remote login is RDP-only (sourced), mstsc cannot speak VNC |
| **Enabling the host firewall** | open question 1; `Enable-` requires a source scope and prints the rule, but does not run `ufw enable` (R9) |
| **Opening 3389 to the internet / an RD Gateway** | never (CISA CM0042); the enterprise path is VPN / Entra Private Access / Arc SSH tunnel |
| **xrdp / a second desktop stack** | Wayland-only image; a second login path is a second attack surface |
| **Promising the client IP for a refused or successful connection** | the daemon logs none (M-R16), `loginctl` shows `0.0.0.0` (M-R35); only a PAM line carries it, and the completed-login case is owed (O-R2) |
| **Shipping a private key in the ISO / an RDP install screen** | every machine would share one identity (#118); enabling is opt-in and post-install |
| **arm64 / headless amd64 RDP** | no daemon there by construction (M-R19); ssh / `Enter-PSSession` is the path |

---

## 11. Limitations — the honest list

| | |
|---|---|
| **RL1** | The **machine RDP credential rests in plaintext** (`credentials.ini`, 0600) even with a TPM, because the service user is not in group `tss` (M-R24); the fix is unmeasured and not unqualified — a TPM seal to PCRs 0–3 breaks across `Update-OS7` (O-R1, open question 4). |
| **RL2** | The mechanism is proven only to the **greeter**; a *completed* per-user login over RDP was not landed in the automated run (M-R34) and is owed (O-R2). |
| **RL3** | No OS/7 machine ships with RDP on, and no cmdlet exists; the end-to-end proof (M-R33) was a hand-driven bench — a finding, not a gate. |
| **RL4** | **v1 ships NO brute-force lockout at either stage** — none on the shared NLA secret and none on the greeter login (the faillock profile is deferred, R10/O-R3/O-R4). This diverges from the Windows default; only credential strength (R4) and the operator source scope (R9) defend the port. |
| **RL5** | **"Who was refused, from where" is not answerable** from the daemon or logind (M-R16, M-R35) — no 4625-equivalent for the brute-force case; and the completed-login success line is owed (O-R2). |
| **RL6** | A **CA-issued / pinned** key inside the BE rolls back while clients still trust it (open question 9, R8). |
| **RL7** | **Domain-user RDP crashes on Ubuntu 26.04** even after the never-run AD Stage 2 (LP #2150612, #2163159, sourced), and clipboard over RDP additionally fails for domain users (`fusermount3: could not determine username`) — not promised. |
| **RL8** | **v1 has no per-user allow-list and cannot exclude admins**: the group, the PAM enforcement and a deny path are deferred behind O-R2/O-R3, so until then any local account that passes the machine credential may reach the greeter — weaker than Windows' *Remote Desktop Users* gate and its "Deny log on" right, and named as such. |
| **RL9** | A **restart on credential/cert change drops live client connections** (M-R28), and `Disable-` stops the unit, which also drops them (a divergence from Windows, R13); its effect on an established *user* session is unmeasured (O-R7). Sessions also accumulate — a new greeter per connection (M-R35/M-R36); reconnect/cleanup is unmeasured (O-R8). |
| **RL10** | The **shipped unit has no sandboxing** (M-R18); a hardening drop-in must be measured against the GDM D-Bus and PipeWire paths first (#33's shape) before it is shipped. **arm64 is entirely unmeasured** — no arm64 GUI ISO exists (O-R10). |
| **RL11** | **Only Windows `mstsc`/FreeRDP are verified** (M-R29/M-R30); the macOS/iOS "Windows App" failed the redirection handover on earlier g-r-d and is unverified on 50.2 (reported, unverified), and any client not advertising RDPGFX is **rejected** by the server (M-R32). |
| **RL12** | **No session idle/disconnect time limits** exist (sourced): a disconnected session persists until logout or reboot, unlike Windows RDS session-limit policies. |
| **RL13** | **The plaintext machine credential is not removed until `Disable-` clears it** (or `-KeepCredential` is used); until then it persists across rollback and — if `/var/lib/gnome-remote-desktop` is on `rpool/DATA` (O-R5) — is copied to backup targets by sanoid/syncoid. |

---

## 12. Open questions

1. **The host firewall** — DECISIONS **open question 1**; `Enable-` requires a source scope and
prints the rule but does not enable ufw (R9). Not decided here.
2. **`Rename-OS7Computer`** — DECISIONS **open question 2** gains a second consumer:
the certificate SAN is the hostname (R7).
3. **The pinned / CA-issued TLS key inside the boot environment** — added to
DECISIONS **open question 9** (the keytab), not a new question (R8).
4. **DECISIONS open question 11 (new)** — the **machine-credential lifecycle across
`Update-OS7` and rollback**: it may survive a rollback outside the BE (pending O-R5) while
`grd.conf` and the cert roll back inside it, and any TPM sealing (O-R1) breaks across an update
that changes PCRs 0–3 (RL1) — so does `Update-OS7` rotate or reseal it, and is a first-boot re-key
wanted if RDP ever ships default-on?
5. **Internal** — the credential-setting mechanism itself (R4/O-R13) and how the one-time reveal
is surfaced; whether the unit gets an OS/7 hardening drop-in (RL10); whether `os7-remotedesktop`
becomes part of the Tier-2 Users surface or stays RDP-local.

---

## 13. What this changes in the repository

* **New file** `powershell/OS7/OS7.RemoteDesktop.ps1` — added in **four** lists nothing asserts
equal, or the build fails silently or the file ships invisible: the `OS7.psm1` dot-source `foreach`
(after `OS7.Service.ps1`, **before** `OS7.Update.ps1`), `FunctionsToExport` in `OS7.psd1` **and**
`Export-ModuleMember`, hook 0060's `check_module OS7 …` list **and** its `for part` loop, and
`pkg_finish os7-module`'s required paths (27 → 28). **`check-ps-traps.py`** must stay green (none of
#65/#82/#91/#112/#119/#121; it scans every `.ps1`).
* **Package list** — name `gnome-remote-desktop` in
`build/config/package-lists-amd64/os7-desktop.list.chroot` so a Recommends change cannot silently
drop it (today it arrives only transitively behind `ubuntu-desktop-minimal`; the #62-shaped argument).
* **Static OS/7-owned artefacts need a named package owner** — the **inert** ufw application profile
`os7-remote-desktop` (R9), the `os7-remotedesktop` **group** (R5, a sysusers drop-in), and the later
`pam-configs`/faillock profile (R5/R10) go in a package `tree/` (the `os7-desktop` tree or a small
dedicated package), not `includes.chroot`; the verifying hook asks dpkg/systemd, not the file it wrote.
* **`OS7.format.ps1xml`** — optional `OS7.RemoteDesktop` `PSTypeName` + view (no new file).
**`check-layering.py`** — no new rule; `run-surface.py` types the new `Get-`/`Test-` verbs.
**`Get-SystemdSession`** is **not a v1 change**: it lands with the deferred session verbs (§6), and
is itself a multi-file edit (Systemd.psd1/psm1, hook 0060's Systemd list, `Test-SystemdModule`,
reference regeneration) enumerated there.
* **`check-remotedesktop-logic.py`** — new (§9 Tier 1); container and `check-image.py` additions
(§9 Tier 2, including the default-OFF assertion O-R14).
* **`installer/testing/os7lab.py`** — a fourth port kind (`rdp`, base 7700) in `Bench.port()`, a
second `hostfwd` to guest 3389 in `qemu_args()`, a fourth `-p` in `detach()`/`write_state()`
(M-R23/M-R31); then `mstsc /v:127.0.0.1:<rdp>`. **The RDP screenshots are new work, not
`shoot-manual.py`** (which logs in locally): the greeter-over-RDP pictures (M-R33) need the bespoke
FreeRDP-under-Xvfb client capturing over the wire — a new harness step.
* **Manual (DE + EN, one source)** — a section in chapter 13 or a §9.x beside 9.4, naming the **two
logins** in Microsoft's German (*Remotedesktop*, *Remotedesktopverbindung*, *Remotedesktopbenutzer*,
*Authentifizierung auf Netzwerkebene (NLA)*), the local/remote session mutual-exclusion (§10), the
`.rdp` template with `use redirection server name:i:1`, and pointing a remote admin at the cmdlets
not the Settings panel (R2). **Appendix C**'s RDP row names `Enable-OS7RemoteDesktop`, `mstsc` and
the machine-credential caveat, both languages. `POWERSHELL-REFERENCE.md` and Appendix A are
**regenerated**, not edited.
* **Pointers** — `CLAUDE.md` authority row + the check command; `README.md` status row;
`DECISIONS.md` a locked bullet, open question 11, the cert on open question 9;
`POWERSHELL-SURFACE-PLAN.md` a RemoteDesktop surface note and its relation to the deferred
Users/Firewall/Certificates tiers; `HANDOFF.md` §1 row + §2 block; a `docs/SESSION-REMOTE-DESKTOP.md`.
New traps start at **#123**; **D17/L36** are reserved as the next SETUP-PLAN numbers only if an
installer change is ever needed — **none is in v1** (R15).

---

## 13a. What building v1 measured, 2026-09-07

Five things the implementation learned that the plan above did not know. Two became
BUILD-NOTES entries; one answers an owed measurement; two are new facts about the daemon.

| # | Fact | How |
|---|---|---|
| **M-R37** | **O-R13 is answered, and the safe route loses.** The README's stdin form for `set-credentials` left the username EMPTY on the real machine while returning 0 — M-R25 reproduced on a booted OS/7 machine, not just in a container. The two-argument form worked. `Set-OS7RdpCredentialValue` therefore tries stdin FIRST, reads the daemon back, and falls back to the argument form, reporting which one worked; the secret is briefly in `argv` on that path and RL1's plaintext note now has a second exposure beside it. A daemon version that fixes the stdin form will make the fallback dead code, and the readback is what will show it. | `Enable-` on the bench, `OS7-STEP the stdin route left the credential unset (M-R25); using the argument form` |
| **M-R38** | **`grdctl --system status` prints `Username: (hidden)` when a credential is set and `(empty)` when not** — so a cmdlet can confirm a credential took WITHOUT `--show-credentials` and therefore without the secret crossing a stream. This is what makes P7 and the readback compatible, and it is the mechanism the whole credential path rests on. | `grdctl` before and after, bench and container |
| **M-R39** | **A never-started unit is in no systemd list**, so `Get-SystemdUnit` returned zero rows for `gnome-remote-desktop.service` on a machine where RDP had never been enabled, and "is it running" came back `$null` where `$false` was the truth. BUILD-NOTES **#124**; it is #116's shape in a third place. | `Get-OS7RemoteDesktop` on a fresh bench |
| **M-R40** | **The daemon binds ONE dual-stack socket.** The kernel's listener list has an IPv6 wildcard entry and no IPv4 one, while an IPv4 client connects perfectly well (measured: FreeRDP over IPv4 to exactly this listener). A cmdlet reporting the two families from the socket list alone says "no IPv4" about a machine that serves IPv4. `Get-OS7RemoteDesktop` reports `ListeningDualStack` for this. | `ss`, `GetActiveTcpListeners`, a real client |
| **M-R41** | **`[System.IO.Directory]` has no `SetUnixFileMode`** — `File`'s overload is `chmod(2)` and takes a directory. The symmetric-looking spelling is a run-time `MethodInvocationException` that no parser check can see. BUILD-NOTES **#123**. | .NET reflection in `os7img:175` |

And the end-to-end run, which is the thing the plan's §1 could not claim before: `Enable-` →
`Test-OS7RemoteDesktop` all green → FreeRDP 3.31 authenticated with the generated credential
(`Authentication only, exit status 1`) → a wrong password refused at NLA
(`SEC_E_MESSAGE_ALTERED`, `client authentication failure` in the machine's journal) → `Disable-`
→ nothing listening, unit `disabled`/`inactive`, `enabled=false`.

---

## 13b. The allow-list and the lockout, built 2026-09-07 - and what measuring them changed

R5 and R10 were deferred behind O-R2, O-R3, O-R4 and O-R18. The measurements were
taken on a booted machine and **three of them contradicted the plan above**, which is
why this section exists rather than a quiet edit to R5.

| # | Fact | How |
|---|---|---|
| **M-R42** | **The enforcement point is `gdm-authd`, not `gdm-password`.** The plan said gdm-password on the strength of upstream sources. A `pam_exec` probe on every login path at once shows BOTH the local greeter login and the one delivered over RDP going through `gdm-authd`. OS/7 writes its rule into both, because a differently configured machine would otherwise be silently unguarded. **O-R2 answered.** | pam_exec probe, one login each way |
| **M-R43** | **`rhost` is the discriminator, measured on both sides.** RDP: `service=gdm-authd rhost=172.17.0.3 tty=<none>`. Console: `service=gdm-authd rhost=<empty> tty=/dev/tty1`. Same service; only the origin separates them. The greeter's own launch environment is `gdm-launch-environment` with `rhost=0.0.0.0` - a different service file, which is why the exemption the plan owed is achieved by NOT touching it rather than by a clause. | the same probe |
| **M-R44** | **`pam_succeed_if rhost = ""` does not work and reads as though it does.** PAM does not strip quotes from a token, so the comparison is against the two characters `""`. Measured: the module logs `'rhost' resolves to ''` and the requirement is still not met. A rule built on it fails OPEN. `pam_access` is used instead. | pam_succeed_if with debug |
| **M-R45** | **The rule is correct in all four quadrants**, measured before a line of it shipped: non-member + remote -> `access denied`; member + remote -> `user_match=0`, allowed; **NON-MEMBER + LOCAL -> `from_match=0`, allowed**; administrator + local -> allowed. The third is the console-lockout case and the reason the feature is safe. pam_access compares the origin against the TTY when there is no remote host, and `LOCAL` matches it. **O-R18 answered for the rule.** | pam_access with debug over ssh-to-self and su |
| **M-R46** | **On the real RDP path the allow-list refuses a non-member**: `pam_access(gdm-authd:auth): access denied for user 'rdtest' from '172.17.0.3'`, with the client's real address. With the account added to `os7-remotedesktop` the deny does not fire. | a FreeRDP client at the greeter |
| **M-R47** | **The safe-failure control passes**: with the policy installed in both gdm services, an administrator signs in at the local console and reaches the OS/7 desktop, and ssh is untouched. Photographed. | os7lab click/type/shot, ssh |
| **M-R48** | **A prepended `pam_faillock authfail` breaks every login on the service** - the local console login failed three times with the same password that had just worked, and removing the two faillock lines restored it. `authfail` must follow the authentication modules, and a service ending in an `@include` has no position a prepending writer can reach. BUILD-NOTES **#125**. | the console login, before and after |
| **M-R49** | **A marker appended to a PAM module line is an ARGUMENT, not a comment.** BUILD-NOTES **#126**. | the written file |

### What this changes in the decisions above

**R5 is amended:** the service is `gdm-authd` (and `gdm-password` for safety), the
mechanism is `pam_access` and not `pam_succeed_if`, the greeter exemption is by service
selection, and the cmdlets `Get-/Add-/Remove-OS7RemoteDesktopUser` are **built** rather
than deferred - their enforcement point is now measured.

**R10 is not met, and is not quietly narrowed.** It said the faillock would live "on the
remote greeter path only, scoped so a lockout never reaches the console". M-R42 makes that
impossible - local and remote graphical logins are the same PAM service - and M-R48 makes
the naive placement actively dangerous. **v1 therefore ships NO account lockout**, and says
so in `Get-OS7RemoteDesktop` (`LockoutEnforced` is always `$false`) and in
`Test-OS7RemoteDesktop`. RL4 stands unchanged and O-R4 is still owed, with a narrower
question: whether a lockout belongs in `common-auth` through `pam-auth-update` - which
would make it account-wide, ssh and the text console included, and is a product decision
rather than a Remote Desktop one.

### RL14 - WITHDRAWN 2026-09-07. There is no such defect, and this is what it cost

**This section previously claimed a product defect that does not exist.** It said a
local account could not complete a sign-in over RDP on `OS7-1.0.0.163-amd64`, because the
remote greeter's authd `local` broker rejected a password the same account and the same
PAM service accepted at the physical console. The measurement was real, the reasoning was
careful, and **the conclusion was wrong**. It was published here, in HANDOFF.md and in a
commit message before it was disproved.

**M-R50 - the sign-in over RDP works, end to end.** Same machine, same account, same
client, password changed to one containing no punctuation: the login completes and the
OS/7 desktop is delivered over RDP. `loginctl` records it as what it is:

```
session 12: Name=os7admin Remote=yes RemoteHost=172.17.0.3
            Service=gdm-authd Type=wayland Class=user State=active
```

**What was really happening.** The machine is installed `XKBLAYOUT="de"` and the greeter
has no GSettings input source, so it uses that. **RDP carries scancodes, not characters**:
the test password `os7-s5-password` was typed through an Xvfb with a US keymap, and the
hyphen key of a US layout is `ß` on a German one. Fifteen keystrokes went in and fifteen
dots appeared in the password field, which was mistaken for proof that the password had
arrived. BUILD-NOTES **#128** is the write-up and the rules it leaves.

**M-R51 amends M-R35, and narrows the audit gap.** M-R35 reported `RemoteHost=0.0.0.0`
and concluded the client address is not available from logind. That was measured on the
GREETER session. **A completed USER session carries the real client address**
(`RemoteHost=172.17.0.3`), so a successful Remote Desktop sign-in IS attributable from
`loginctl` alone. RL5 stands only for the REFUSED case, which still leaves no address
anywhere OS/7 can read.

**O-R2 is answered in full.** The service is `gdm-authd`, the local account falls through
to `pam_unix`, the login completes, and the session is a remote wayland user session.

**What this leaves as a real limitation, and it is a different one:** a test that types a
credential across a keyboard boundary is measuring the boundary as much as the product.
The bench's own default password contains hyphens, so any future RDP login test must use a
layout-invariant credential or pin both layouts and assert them.

---

## 14. Measurements owed before locking

The `O-R` prefix marks these owed, distinct from the measured `M-R` above.

* **O-R1** (RL1, oq4) — add `gnome-remote-desktop` to `tss`: does `set-credentials` TPM-seal, to which PCRs, **and does the seal survive `Update-OS7`** (else re-key on first boot)? → bench.
* **O-R2** (R5, RL2, RL5, R11) — the remote-greeter PAM service and the **local-account fall-through** over RDP (does `pam_unix` run and emit an rhost success line), completing M-R34. → bench: a *completed* login, then `journalctl … gdm.service`.
* ~~**O-R3**~~ **ANSWERED 2026-09-07 (M-R42/M-R44/M-R45)**, and differently from how it was asked: there is no `pam-auth-update` profile and no `pam_succeed_if`. The rule is one `pam_access` line in `gdm-authd` and `gdm-password`, the greeter exemption is by service selection, and all four quadrants were measured. What is still owed is the **admin deny path** - a way to forbid administrators from connecting, which CISA CM0042 recommends and v1 does not have.
* **O-R4** (R10, RL4) — NARROWED by M-R42/M-R48: a lockout cannot be scoped to the remote path, because local and remote graphical logins are one PAM service, and it cannot be prepended, because `authfail` must follow the authentication modules. The open question is whether it belongs in `common-auth` through `pam-auth-update` - account-wide, ssh and the text console included. That is a product decision. → bench, after it is taken.
* **O-R5** (R8, R15, RL13) — whether `/var/lib/gnome-remote-desktop` and `/var/lib/os7/remote-desktop` sit on `rpool/DATA` (deciding rollback and backup propagation). → bench: `zfs list` + `stat`.
* **O-R6** (R11, RL5) — any peer IP for a **refused** connection. → container + FreeRDP.
* **O-R7** (RL9) — what a unit restart/stop does to an **established** session. → bench.
* **O-R8** (RL9) — attach-vs-new when a user is logged in **locally**, the force-kill dialog, and reconnect/cleanup as sessions accumulate (M-R35/M-R36). → bench.
* **O-R9** (§9) — **mstsc** against 50.2 end to end: cert-warning wording, the insecure-connection dialog without `use redirection server name:i:1`, NLA order. → fourth `os7lab.py` port + manual mstsc.
* **O-R10** (RL10) — arm64 entirely: there is no arm64 GUI ISO. → build one.
* **O-R11 / O-R12** — whether `gnome-classic.desktop` carries `X-GDM-CanRunHeadless=true` (→ `check-image.py`), and whether g-s-d reports OFFLINE on a networkd machine (LP #2141992; → bench).
* ~~**O-R13** (R4) — the credential-setting invocation~~ **ANSWERED 2026-09-07 (M-R37/M-R38)**: the stdin form silently fails on 50.2, the argument form works, and `(hidden)`/`(empty)` in plain `status` is the readback that confirms without revealing. v1 tries stdin, reads back, falls back. What REMAINS owed is narrower: a route that keeps the secret off `argv` on this daemon version at all — there may not be one, in which case RL1 gains a second sentence.
* **O-R14** (R3, §9) — on the ISO squashfs, `gnome-remote-desktop.service` is **not** in `graphical.target.wants` and reads `disabled` (the falsifiable form of default-OFF). → `check-image.py`.
* **O-R15** (R5) — which session a **completed** RDP login lands in (gnome-classic expected, AccountsService precedence) and whether its terminal reaches PowerShell (#86 control). → bench, after O-R2.
* **O-R16** (§5) — multi-monitor / virtual-monitor (NEWS 49.rc), dynamic resolution on resize, and **German-keyboard scancode fidelity** over RDP. → bench + manual mstsc.
* **O-R17** (R2, R7) — whether a Settings-written **local-state** `grd.conf` (`/var/lib/…`) can override `/etc`, and where a Settings-imported cert lands. → bench.
* ~~**O-R18**~~ **ANSWERED 2026-09-07 (M-R45/M-R47)**: a non-member is allowed on a local origin (`from_match=0`), and with the policy installed an administrator signs in at the physical console and reaches the desktop while ssh is untouched. `check-remotedesktop-logic.py` holds the file half of it - the rule must never appear in `login`, `sshd`, `su`, `sudo` or `common-auth`.
