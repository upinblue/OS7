# OS/7 — the PowerShell system surface

**This file is authoritative for what OS/7 exposes as cmdlets, what it
deliberately does not, and how the layers below them are cut.** Started
2026-08-27. Decisions are P1–Pn; open questions are at the end and are flagged
before an irreversible choice depends on one.

It exists because of one sentence in
[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §6:

> The goal is that an operator never needs the Linux commands. That holds only
> if the surface is complete — a single missing verb sends them back to bash and
> the guarantee is gone.

§6 of that file then lists eight cmdlets, all of them about the release train.
That is the whole surface this project had specified: a machine that can update
itself and cannot be given an IP address. This file is the rest of it.

Related authority: [DECISIONS.md](DECISIONS.md) for what is locked overall,
[ZFS-POWERSHELL-PLAN.md](ZFS-POWERSHELL-PLAN.md) for Z1 — the layering rule this
file generalises — and [BUILD-NOTES.md](BUILD-NOTES.md) for the traps every
cmdlet below is written against.

---

## 1. What was measured, and what was not

Everything in §2 rests on this. Taken 2026-08-27 from `os7img:116`, the shipped
**amd64** image (`IMAGE_VERSION=1.0.0.116`), in a container.

**A container has no running systemd and no dbus.** So what follows is the
presence of binaries, packages and cmdlets — **not behaviour**. Nothing here has
been measured on arm64 at all: no arm64 image was available on the host that ran
this. Both gaps are stated rather than papered over, for the reason BUILD-NOTES
keeps re-learning: "cannot tell" is not "clean".

> **RE-VERIFIED AGAINST THE ISO, 2026-08-27, and one measurement in seven had
> been wrong.** `os7img:116` is a container image *derived from*
> `OS7-1.0.0.116-amd64.iso`, and it carried a `/etc/pam.d/common-auth` that the
> shipped ISO does not — modified after the ISO was written and before the
> container was created. It nearly went into BUILD-NOTES as a serious product
> defect. **BUILD-NOTES #93** is the write-up and the rule: an artefact derived
> from the product is not the product.
>
> Everything else in this section was re-checked by mounting the ISO's squashfs
> and held: `sshd_config` offering only `sftp` with zero drop-ins, `chrony`
> present and `systemd-timesyncd` absent, the `/etc/localtime` symlink with no
> `/etc/timezone` and no `/etc/adjtime`, the profile.d hand-off present,
> `/etc/netplan` empty, PowerShell 7 present.
>
> One thing the ISO added: **`/etc/authd/brokers.d` is empty**. authd is
> installed and PAM is wired to it, and there is no broker for it to talk to —
> so **Entra sign-in cannot work on an OS/7 image as built today**. C8a says so
> as an open question; this is the first time it has been measured on the
> artefact rather than reasoned about, and it is what the management-plane
> cmdlets will have to report.

### 1.1 PowerShell 7.6.5 on Linux already owns some of these nouns — half of them

| present | absent |
|---|---|
| `Get-TimeZone` — works, returned `Etc/UTC`; .NET sees 419 zones | **`Set-TimeZone`** |
| `Restart-Computer`, `Stop-Computer` | `Get-ComputerInfo`, `Rename-Computer` |
| `Enter-PSSession`, `Invoke-Command`, `New-PSSession` | — |
| `Get-Process`, `Stop-Process`, `Get-Date`, `Set-Date`, `Test-Connection`, `Get-FileHash`, `Get-Credential`, `Get-Culture`, `Get-PSDrive`, `Get-Clipboard` | `Get-Service` and the entire service family, `Get-LocalUser`, `Get-LocalGroup`, `Get-WinEvent`, `Get-EventLog`, `Get-Disk`, `Get-Volume`, `Get-ScheduledTask`, `Get-HotFix`, `Get-BitLockerVolume`, `Resolve-DnsName`, every `Net*` |

The `TimeZone` noun is the sharp one: it is occupied, with exactly one verb. An
admin reads the zone out and finds nothing to set it with. P1 decides what OS/7
does about that, and open question 3 records that the answer is not comfortable.

### 1.2 Present in the image

`networkctl netplan NetworkManager nmcli resolvectl timedatectl hostnamectl
localectl systemctl journalctl chronyc ufw nft iptables dmidecode mokutil
tpm2_getcap cryptsetup update-ca-certificates useradd loginctl busctl udevadm ip
iw rfkill sshd`

Three findings out of that list matter more than the list:

* **Time is `chrony 4.8-2ubuntu1`, and `systemd-timesyncd` is not installed.**
  Anything written against timesyncd would be written against a package that is
  not there.
* **`ufw`, `nftables` and `iptables` are all installed and are in no
  package-list.** They arrived transitively behind the desktop. arm64 is
  server-only and never installs that list, so on arm64 this is unmeasured and
  probably absent — see open question 1.
* **`sshd_config` carries `Subsystem sftp` and nothing else.** So
  `Enter-PSSession -HostName …` fails against an OS/7 machine today, although
  PowerShell's own half of it is present and working. The gap is one
  configuration line.

### 1.3 The LDAP stack on Linux — one foundation and one trap, and they load alike

Measured 2026-08-27 in pwsh 7.6.5 on the shipped amd64 image, and against a real
Samba AD DC in a container (`installer/testing/Dockerfile.ad-dc`, realm
`OS7.TEST`, Samba 4.23.6). §1.1 asked which nouns PowerShell already owns; this
asks what is underneath the noun a Microsoft administrator cares about most.

* **`System.DirectoryServices.Protocols` ships inside pwsh 7.6.5 and works.** It
  resolves with no `Add-Type`, opens a socket and reaches `libldap` — which is
  on every OS/7 image whether anybody planned it or not: `libldap2` is a
  `Depends` of `libcurl4t64` and `curl` is in `os7-base.list.chroot`, on **both**
  architectures. The client itself needs no new package. (Three were added to
  the base list anyway — `ldap-utils`, `libsasl2-modules-gssapi-mit`,
  `bind9-dnsutils` — and none of them is the client: they are the independent
  witness, the GSSAPI mechanism plugin, and the SRV lookup that finds a domain
  controller.)
* **`System.DirectoryServices` — ADSI — loads, and then throws.** The assembly
  resolves, the type resolves, and the first call says it is not supported on
  this platform. One of these two namespaces is a foundation and the other is a
  dead end; they are one word apart, they fail at different moments, and
  **nothing tells them apart except running the code.** The AD scripts an
  administrator arrives with are written against the second one.
* **`AuthType.Negotiate` with an explicitly supplied credential returns LDAP
  result 92, "not supported"** — with the GSSAPI plugin present. Negotiate works
  from an **ambient** ticket, and then only with `rdns = false` in `krb5.conf`
  *and* `SASL_NOCANON` on for OpenLDAP; otherwise the client canonicalises the
  server through reverse DNS and asks the KDC for a principal that does not
  exist. So a typed-in credential is a **simple bind**, which forces the next
  finding.
* **A simple bind on port 389 is refused by Active Directory** — "Strong
  authentication is required" — and LDAPS on 636 is accepted. Windows answers
  that with sign-and-seal, and **`SessionOptions.Sealing` throws on Linux**.
  There is no third option, so TLS is the default and port 389 is opt-in.
* **`SessionOptions.VerifyServerCertificate` throws as well.** There is no
  certificate callback on this platform at all, so trust belongs to OpenLDAP,
  and OpenLDAP's trust is **machine-wide** — a product decision taken by an
  absent API rather than by anybody here (open question 8).
* **`$env:LDAPTLS_CACERT` set from inside PowerShell does nothing**, and reads
  back correctly while doing nothing. .NET on Unix keeps its own copy of the
  environment block and never calls `setenv(3)`, so no native library ever sees
  the value while `[Environment]::GetEnvironmentVariable` answers happily from
  the copy. A real `setenv(3)` does work, and only before the first LDAP call in
  the process. The failure presents as **"The LDAP server is unavailable"** — a
  network message, about a server that is answering, for a trust problem.
* **`SessionOptions.ProtocolVersion` reads back 2.** AD refuses LDAPv2 and the
  refusal arrives as a failed bind, which reads as a wrong password. Version 3
  has to be set explicitly on every connection.
* **`ReferralChasing` defaults to `All`.** Every search against a domain root
  returns three referrals, and chasing one opens a **second, unauthenticated**
  connection to another server. Switching it off is not tuning; it is the
  difference between asking as somebody and asking as nobody.
* **`SearchResultEntry` has no public constructor** — none of the result types
  do. A test cannot manufacture a directory reply, which is why the seam the
  self-test replaces sits **above** the .NET boundary and not below it: a
  testing decision forced by a sealed API. It is what lets
  `Test-DirectoryModule` run 40 checks with no server while `check-ad.py` needs
  a real one.
* **And what a Windows administrator reaches for next is not there: WinRM.**
  PowerShell on Linux answers "no supported WSMan client library was found".
  §1.1's remoting row is SSH transport and only SSH transport.

One measurement about the rig rather than the product, kept because the next
person to build one would otherwise spend the same afternoon: on Ubuntu 26.04 the
AD DC role is in **`samba-ad-dc`** and **`samba-ad-provision`**, not in `samba`;
`samba-tool` arrives with `python3-samba`, which is only a `Suggests`; and
provisioning inside a container needs the `posix:eadb` ACL backend, because
writing SYSVOL's NT ACLs otherwise needs `CAP_SYS_ADMIN`.

---

## 2. Decisions

### P1 — The `OS7` prefix is canonical. Decided 2026-08-27.

`Get-OS7Service`, `Set-OS7TimeZone`, `Get-OS7NetworkAdapter`. Not `Get-Service`,
not `Set-TimeZone`, even where §1.1 shows the name to be free on Linux today.

Three reasons, in order of weight:

1. **A free name is not a free name for ever.** PowerShell ships `Get-TimeZone`
   on Linux and not `Set-TimeZone`; that asymmetry is a decision Microsoft can
   revisit in any release. An OS/7 function under the same name would then
   shadow theirs inside a session, silently, with a different parameter set.
   That is the shape of #85 and #73 — every declaration satisfied and the thing
   they were about decided elsewhere.
2. **Our parameter sets will never match Windows.** `New-NetFirewallRule` on
   Windows has some forty parameters. A cmdlet that takes the same name and
   accepts a third of them turns a copied script into one that half-works, which
   is worse than one that fails at the first line.
3. The existing module already prefixes everything, and a surface that is half
   prefixed is a surface nobody can guess at.

**The Windows names are not abandoned; they are deferred to an opt-in
`OS7.Compat.Windows` module**, which nothing imports by default, which contains
aliases and only aliases, and which may only carry a name where the *common
invocation* is genuinely equivalent. Each entry needs a row in a table that a
test drives. An alias that is nearly right is the thing this decision exists to
avoid, so shipping one carelessly under a compatibility banner would defeat it.

### P2 — Subsystems get a generic module; OS/7 policy sits above it. Decided 2026-08-27.

This is [ZFS-POWERSHELL-PLAN.md](ZFS-POWERSHELL-PLAN.md) Z1 generalised.
`powershell/Zfs/` knows nothing about OS/7 and would run on any OpenZFS host;
`powershell/OS7/` is the product on top. `installer/testing/check-layering.py`
holds that line at a baseline that may fall and may not rise.

The split earns its keep where **the subsystem has its own vocabulary and the
product has a policy on top of it**. That is exactly the network's shape: netplan,
networkd, NetworkManager and resolved are generic and would serve any Ubuntu
host, while "which renderer" is a product decision derived from the install mode
(SETUP-PLAN D14). So:

| module | knows | does not know |
|---|---|---|
| `powershell/Net/` | `ip`, netplan, networkd, NetworkManager, `resolvectl`, `iw`, `rfkill` | boot environments, install modes, Entra, OS/7 at all |
| `powershell/OS7/` | which renderer this machine takes, which endpoints must be reachable, what an enrolled machine may not be renamed to | how to spell a netplan document |

`check-layering.py` gains a second line with this: **`powershell/OS7` must not
invoke `ip`, `netplan`, `nmcli`, `networkctl` or `resolvectl` directly.** Same
mechanism, same baseline rule.

Where there is no product policy — services, the journal, processes — a generic
module alone is the whole answer and the OS/7 layer adds nothing but a curated
view. **The split is justified per subsystem, not applied by reflex**; §3 says
which get one.

> **This clause originally offered the time zone as the example of a subsystem
> too thin to warrant a module, and building it proved that wrong.** The zone is
> a symlink; what is behind it is not. The image runs **chrony 4.8, not
> systemd-timesyncd** (§1.2), with its own vocabulary, its own CSV format, and a
> configuration mechanism that is not the file everybody assumes — so
> `powershell/Time/` exists and `check-layering.py` gained a third rule. The
> measurement corrected the plan rather than the other way round. What survives
> of the clause is its point: ask per subsystem.

### P3 — The netplan renderer moves to PowerShell, in two steps. Decided 2026-08-27.

Today it is `NetworkPlan.ToNetplanYaml` in C#
([installer/src/OS7.Setup/Model/NetworkPlan.cs](../installer/src/OS7.Setup/Model/NetworkPlan.cs)),
a pure function with eight cases asserted in `--self-test`. Writing a second one
in PowerShell from the same notes is **BUILD-NOTES #66 exactly** — the paraphrase
that takes a different route, which nobody diffs, and which is discovered by a
machine that has no address and reports no error.

SETUP-PLAN §6.3 already made this move once, for storage, and it is proven:
`os7-setup` shells out to `pwsh -NoProfile -Command 'New-OS7Storage …'`
([StorageSteps.cs:415](../installer/src/OS7.Setup/Steps/StorageSteps.cs:415)),
and `run-phase3.py all` has passed on that path. So calling PowerShell from the
installer is an established mechanism, not a new dependency.

**Step 1 — no VM, no install path touched.** `New-NetplanDocument` in
`powershell/Net/`, plus `installer/testing/check-netplan-rule.py`, which owns the
case table and drives **both** implementations, requiring **byte-identical**
YAML. Modelled on `check-version-rule.py` down to its reporting rule: when the
C# half cannot be run, it is reported as NOT CHECKED rather than skipped. The C#
side gains an argv mode `--netplan-render` for this and nothing else; the install
path is not touched.

**Step 2 — needs the Apple Silicon host.** `NetworkStep` calls the module, the
C# renderer is deleted, and `run-phase3.py all` is the gate. Until that run, the
repository deliberately holds two implementations and one specification.

Between the two steps the state is the `check-version-rule.py` state — a rule
written twice with one owner — which is a supported state here, not an accident.

### P4 — What PowerShell already does on Linux is not rebuilt. Decided 2026-08-27.

No `Get-OS7Process`, `Get-OS7FileHash`, `Restart-OS7Computer`, `Get-OS7Date`,
`Test-OS7Connection`, `Get-OS7Credential`. §1.1 measured every one of those as
present and working. A wrapper would be a second, slightly different behaviour
beside a working one, and the surface would grow without the guarantee in §6
getting any closer.

The test for admission is not "would this be convenient". It is **"does an
operator otherwise have to type a Linux command"**. That is what §6 promises and
it is the only thing that justifies the maintenance.

### P5 — Every cmdlet asks the thing itself.

Restated here because this surface is where it is easiest to break. The recurring
expensive bug in this repository is *a program reported success and the thing it
was meant to change did not change* — #73, #85, #62, #64, #78. An exit code is a
diagnostic; so is a log line.

Concretely, for this surface:

* `netplan apply` returns 0 for a configuration that brings nothing up. The
  answer comes from `ip`. `NetworkProbe` already does this and the cmdlets
  inherit the rule.
* `timedatectl` answers "System clock synchronized" from a kernel flag.
  Whether the clock is actually being disciplined, and against whom, is
  `chronyc tracking`.
* `systemctl is-active` says `active` for a unit in a restart loop.
  `ActiveState` alone is not a health answer; `SubState`, `Result` and
  `NRestarts` are part of it.
* `useradd -m` exits 0 and does nothing when the home directory exists (#78).

### P6 — Two fields, never one: configured and effective.

Every `Get-OS7*` that can be asked about something with both a stored intent and
a running reality returns **both, separately, never merged**. `Get-OS7NetworkConfiguration`
reports what the netplan documents say *and* what the kernel has. A single field
would have to pick one, and the interesting case — a machine whose configuration
and reality disagree — is exactly the one it would hide. L28 is that failure
having happened.

### P7 — Secrets are never serialised, and the file is 0600 before it is written.

L25, generalised off the network. A Wi-Fi passphrase, a LUKS passphrase and an
account password each reached this rule separately and each was written as though
it were the only one. Any cmdlet taking a secret takes it as `[securestring]` or
`[pscredential]`, never `[string]`; never writes it into an object that can reach
`ConvertTo-Json`, a log or a screen; and creates the file with its final mode
before the content goes in, not after.

### P8 — The directory is a subsystem; the domain is policy. Decided 2026-08-27.

**`powershell/Directory/` speaks LDAP and realm membership and has never heard of
OS/7; `powershell/OS7/` knows which domain this machine administers, whose
credential the session is holding, which groups may sign in, and that a clock
five minutes out is a Kerberos failure — which does not report itself as a clock
problem, it reports that the password is wrong.**

P2 applied to a fifth subsystem, and it passes P2's own test on the same grounds
the network did: the subsystem has a vocabulary entirely its own — a DN, a search
filter, `userAccountControl`, a keytab principal, an LDAP result code — and the
product has a policy on top of it that cannot be said in that vocabulary at all.

| module | knows | does not know |
|---|---|---|
| `powershell/Directory/` | `LdapConnection` and its TLS, paged search, add/modify/delete/move, `unicodePwd`, the escaping and DN rules, `adcli`, `kinit`, `klist`, `getent`, what an sssd stanza looks like | which domain, which groups, five minutes, boot environments, OS/7 at all |
| `powershell/OS7/` | which domain this machine administers, whose credential the admin session holds, which groups may sign in, that Kerberos dies at five minutes' skew, every `OS7`-prefixed name | how to escape a filter, how to spell a DN, how to drive `adcli` |

The cut falls where a socket is opened or a process is started: **both** of those
are the generic module's, including realm membership, which is `adcli` and
`kinit` and nothing more product-specific than that. Joining a Kerberos realm and
configuring sssd is ordinary Ubuntu; *which* realm, and what a machine does about
it afterwards, is not.

The same line was drawn a second time in the other direction, and that one is
worth naming: **finding a domain controller is an SRV lookup, and DNS belongs to
the network, not to the directory.** `Resolve-NetSrvRecord` is therefore in
`powershell/Net/`, and `dig`, `host` and `nslookup` joined **P2's** token list on
the day this rule was written — where they measure 0. A line is cheapest to draw
before anything has crossed it, which is the argument P2's own baseline already
made once.

**What this forbids: `powershell/OS7` may not name `adcli`, `kinit`, `klist`,
`getent` or `ldapsearch`** — nor `realm`, `sssctl`, `kdestroy`, `ktutil` or the
rest of the Kerberos and OpenLDAP client tools; the whole token list lives in the
rule. `installer/testing/check-layering.py` gained a fifth rule, `P2-directory`,
at a baseline of **1**, with that one site named in the rule itself rather than
left to be found: `powershell/OS7/OS7.Home.ps1:122` asks `getent passwd` about a
**local** account, which predates the directory layer and is the one question
`getent` answers with no directory involved. Not 0 as P2 and P2-time managed by
being written before there was any code to grandfather, and not deliberately
above zero as P2-systemd's 2 is — just one call that was already there. A
baseline may fall and may not rise.
`getent` is in the token list regardless of that site, because the moment sssd is
configured it becomes the canonical "is the join working" probe — and that call
belongs to the Directory module.

It forbids one more thing, quieter and more expensive: **`powershell/OS7` may not
write its own filter escaping or DN handling.** The Directory module exports
`ConvertTo-DirectoryFilterValue`, `ConvertTo-DirectoryDnValue`,
`ConvertTo-DirectoryDomainDn` and `Split-DirectoryDn` for the layer above to
call, which is not tidiness — a second implementation of an escaping rule is
BUILD-NOTES #66 exactly, one specification taking two routes with nobody diffing
them, and the failure it makes is a search that returns the wrong objects rather
than an error. The directory's own design is
[AD-PLAN.md](AD-PLAN.md); this decision is only where its layer boundary is
recorded.

### P9 — Timers are a noun, not a service type. Decided 2026-08-29.

**`Get-OS7Service` stays deliberately services-only, and scheduled work gets its
own noun: `Get-/Enable-/Disable-/Start-/Register-/Unregister-OS7ScheduledTask`,
over the Systemd module's `Get-/New-/Remove-SystemdTimer`.**

This resolves the decision BUILD-NOTES #113 left open — *"either
`Get-OS7Service -Type`, or a separate noun for timers"* — and it resolves it the
way Windows itself does: `Get-Service` does not list scheduled tasks, and
services.msc and taskschd.msc are different tools because "is this program
running" and "will this job run at three in the morning" are different
questions. A `-Type` parameter would have answered #113's literal symptom and
handed a Windows admin a `Get-OS7Service` whose objects are sometimes services
and sometimes not.

The noun carries the policy the generic layer deliberately does not:

* **`Healthy` names the enable-without-start trap** (#115): `systemctl enable`
  arms the next boot only, so `enabled` + `inactive` is a timer that never
  fires and reports nothing. `Enable-OS7ScheduledTask` therefore enables AND
  starts; the generic verbs stay separate so the distinction remains visible.
* **The listing is a union** (#116): a disabled timer is invisible to
  `list-timers --all` and `list-units --all` both, so `Get-SystemdTimer` merges
  `list-unit-files` with `list-timers` and falls through to `systemctl show` —
  a task registered `-Disabled` does not vanish from the inventory.
* **Running a task now means starting the SERVICE** — starting the timer merely
  arms the schedule, and a manual run moves `LastResult`, never `LastRun`
  (measured; the schedule did not fire).
* **`Unregister-` refuses anything not named `os7-task-*`**, by name and before
  any systemd call: registered tasks are the operator's, `sanoid.timer` and
  `os7-update-check.timer` are packages', and a package's schedule is disabled,
  not deleted.
* **A calendar spec is judged by `systemd-analyze calendar` before anything is
  written** — the visudo pattern (A10): the parser that will read the file is
  the one that validates it, and a spec systemd cannot parse would otherwise
  become a timer that never fires and says nothing.

What this deliberately does not do: no second snapshot schedule (the backup
schedule IS sanoid's own timer, BACKUP-PLAN), no transient `systemd-run` jobs
(`systemd-run` stays in P2-systemd's forbidden-token list), and no monotonic
trigger authoring in v1 (`-OnCalendar` is the escape hatch; existing monotonic
timers are still listed and their `OnStartupUSec=` shows in `Schedule`).

---

## 3. The surface

Tiers are by whether §6's guarantee survives without them, not by effort.

### Tier 1 — without these the guarantee in §6 is already broken

| Group | Cmdlets | Layer |
|---|---|---|
| **Network** | `Get-OS7NetworkAdapter`, `Get-OS7NetworkConfiguration`, `Set-OS7NetworkAdapter`, `Test-OS7Network`, `Get-OS7WirelessNetwork`, `Connect-OS7WirelessNetwork`, `Get-/Remove-OS7WirelessProfile`, `Get-/Set-OS7DnsConfiguration`, `Resolve-OS7Name`, `Get-/Set-OS7Proxy`, `Get-OS7ComputerName`, `Rename-OS7Computer` | `Net` + OS7 (P2) |
| **Time** | `Set-OS7TimeZone`, `Get-/Set-OS7Time`, `Get-/Set-OS7TimeSynchronization`, `Sync-OS7Time` | OS7 only — too thin to split |
| **Management plane** | `Get-OS7EntraStatus`, `Register-OS7Entra`, `Get-OS7IntuneEnrollment`, `Register-/Unregister-OS7Intune`, `Test-OS7Compliance`, `Get-OS7ArcStatus`, `Connect-/Disconnect-OS7Arc` | OS7 only — it is the product |
| **Services and logs** | `Get-OS7Service`, `Start-/Stop-/Restart-/Set-OS7Service`, `Get-OS7Log`, `Get-OS7InstallLog` | `Systemd` + a curated OS7 view |
| **Capstone** | `Get-OS7SystemStatus`, `Test-OS7Health` | OS7 |

Time is Tier 1 and not a convenience: **clock skew beyond about five minutes
breaks Kerberos and with it the Entra logon** that is this product's headline
feature.

### Tier 2 — the working day

| Group | Cmdlets |
|---|---|
| **Users** | `Get-OS7User`, `New-/Set-/Remove-OS7User`, `Get-/Add-/Remove-OS7Administrator`, `Get-OS7Session`, `Disconnect-OS7Session` |
| **Disks and encryption** | `Get-OS7Disk`, `Get-OS7Volume`, `Get-OS7Encryption`, `Add-/Remove-OS7EncryptionKeyProtector`, `New-/Get-OS7RecoveryKey`, `Backup-OS7RecoveryKey`, `Unlock-OS7Volume` |
| **Firewall** | `Get-/Set-OS7FirewallProfile`, `Get-/New-/Remove-OS7FirewallRule` |
| **Remoting** | `Enable-/Disable-/Get-OS7Remoting` |
| **Inventory** | `Get-OS7ComputerInfo`, `Get-OS7SecureBoot`, `Get-OS7Tpm`, `Get-OS7Hardware` |
| **Certificates** | `Get-/Import-/Remove-OS7Certificate`, `Test-OS7Certificate` |
| **Directory** | `Enter-/Get-/Exit-OS7AdminSession`, `Get-OS7ADDomain`, `Get-OS7ADDomainController`, `Test-OS7Directory`, `Add-OS7DirectoryTrust`, `Get-OS7ADUser/Group/GroupMember/Computer/OrganizationalUnit/Object`, `Search-OS7AD`, `New-/Set-OS7ADUser`, `New-OS7ADGroup`, `Add-/Remove-OS7ADGroupMember`, `Enable-/Disable-/Unlock-OS7ADAccount`, `Reset-OS7ADAccountPassword`, `Move-/Rename-/Set-/Remove-OS7ADObject`, `Get-/Join-/Repair-/Remove-/Test-OS7Domain`, `Get-/Set-OS7DomainLogonPolicy`, `Get-/New-/Remove-OS7KerberosTicket` |

**Directory is Tier 2, and the argument is written down because the row could be
read into either neighbouring tier.**

It is not Tier 1. Tier 1's test is whether §6's guarantee is *already* broken
without the group, and on the machine OS/7 ships — whose management path is
Entra, Intune and Arc — nothing about Active Directory arises at all. A machine
with no directory in sight is not a broken machine.

It is not Tier 3 either, and that is the sharper half. Tier 3 is completeness;
this is what a Microsoft administrator does between nine and five. Without it the
answer to "unlock that account" is a Windows box, and the answer *on this
machine* is `ldapsearch` and `adcli` — Linux commands, which is exactly what §6
promises an operator never has to type. The whole design is a workstation story:
an administrator signs in to AD from an OS/7 machine with their own AD admin
account and works as themselves, and **the machine is not a member of the domain
and does not need to be.**

The domain join shares the row and is the piece whose tier may move. For a joined
machine `Test-OS7Domain` is the only thing that will say why nobody can log in,
which is Tier 1's shape precisely. It is here instead because **no OS/7 machine
has ever joined a domain** — the join is code plus a container test — and a tier
is a claim about a machine that exists. If joining becomes a supported install
mode, `Get-/Test-/Repair-OS7Domain` moves up with it, and this paragraph is what
makes that a decision rather than a drift.

`New-OS7User` is not a `useradd` wrapper. It is the only correct path on this
product: the home has to be a USERDATA dataset (#74) and `useradd -m` will not
create one, nor will it populate or chown a home that already exists (#78). It
joins the existing `Get-OS7Home` / `Move-OS7Home`.

`Get-OS7Encryption` and the key-protector cmdlets are where #69 lands — TPM
enrolment belongs on first boot, not in the installer, and no code owns that
moment yet.

`Get-OS7Certificate` must report the stores **separately**. The system store is
not the only one: .NET, Edge and Firefox (NSS) and Java each keep their own, and
the classic support case is a root CA imported into the system store after which
the browser still refuses.

### Tier 3 — completeness

`Get-/Set-OS7Locale`, `Get-/Set-OS7KeyboardLayout` (console and desktop are two
settings, and screen 3 collects both at install time with no runtime verb to
match), `Get-/Set-OS7PowerPlan` (logind and GNOME set the same thing in two
places and the winner is not the obvious one — the #85 shape),
`Get-OS7PackageDrift` as a public verb for what `Get-OS7Version -CheckDrift`
already computes privately. The scheduled-task group sat here until 2026-08-29;
it was pulled forward by BUILD-NOTES #113 — the unattended update timer, the
mechanism §6 of the release plan ships so nobody types `Update-OS7`, was
invisible to the whole surface — and is built (P9, §3a).

### Not built — P4

`Get-OS7Process`, `Get-OS7FileHash`, `Restart-OS7Computer`, `Get-OS7Date`,
`Test-OS7Connection`, `Get-OS7Credential`, `Get-OS7Clipboard`.

---

## 3a. What is built, as of 2026-08-27

The network group's READ half, in both layers. Nothing writes yet.

| | State |
|---|---|
| `New-NetplanDocument` | **Done and checked against the C# renderer byte for byte** — `installer/testing/check-netplan-rule.py`, 17 cases plus the refusal, both halves green. P3 step 2 is not done and needs the Mac. |
| `Get-NetLink`, `Get-NetRoute`, `Get-NetRadio` | **Done.** Checked against recorded real `ip -j` / `rfkill -J` output shipped in `powershell/Net/tests/fixtures/`, and run against the real `ip` in the shipped image. |
| `Get-NetplanConfiguration` | **Done.** Asks netplan through its own `--root-dir`, so the self-test checks it against a tree it builds. |
| `Test-NetModule` | 57 checks, green. |
| `Set-NetplanDocument`, `Remove-NetplanDocument`, `Invoke-NetplanApply`, `Wait-NetLinkAddress` | **Done.** Three calls and not one, so that "apply" and "did it work" ask different subsystems. |
| `Get-OS7NetworkAdapter`, `Get-OS7NetworkConfiguration`, `Set-OS7NetworkAdapter`, `Test-OS7Network`, `Get-OS7Endpoint` | **Done.** `installer/testing/check-network-logic.py` — 34 checks over eleven machines, no network, no VM. P2 holds: `powershell/OS7/OS7.Network.ps1` invokes `ip`/`netplan` nowhere. |
| **Time** — `powershell/Time/`: `Get-ChronyTracking`, `Get-ChronySource`, `Get-/Set-ChronySourceFile`, `Sync-ChronyClock`, `Get-/Set-SystemTimeZone`, `Get-SystemClock` | **Done.** `Test-TimeModule`, 33 checks, green — against **recorded real `chronyc -c` output** in `powershell/Time/tests/fixtures/`, in both the synchronised and the unsynchronised state, plus a zone tree it builds. Run live against a real `chronyd -x`. |
| **Time** — OS/7 layer: `Set-OS7TimeZone`, `Get-OS7Time`, `Get-/Set-OS7TimeSynchronization`, `Sync-OS7Time` | **Done.** `check-layering.py` gained a third rule (`P2-time`) and it holds at 0. |
| **Remoting** — `Get-OS7Remoting`, `Enable-OS7Remoting`, `Disable-OS7Remoting`, plus the shipped drop-in `build/config/includes.chroot/etc/ssh/sshd_config.d/60-os7-powershell.conf` | **Done, and tested against a real sshd** — `installer/testing/check-ssh-login.py`, 15 checks. Two mechanisms, reported separately (see below). |
| **Services and logs** — `powershell/Systemd/`: `Get-SystemdUnit`, `Start-/Stop-/Restart-SystemdUnit`, `Set-SystemdUnitStartup`, `Update-SystemdUnit`, `Get-SystemdJournal` — and, since 2026-08-29, `Get-/New-/Remove-SystemdTimer` | **Done.** `Test-SystemdModule`, 76 checks (32 until the timer surface landed), against recorded real `systemctl`/`journalctl` output taken from containers running real systemd — including a journal MESSAGE that is a **byte array** and the enabled-but-never-started timer state (#115). |
| **Services and logs** — OS/7 layer: `Get-OS7Service`, `Start-/Stop-/Restart-/Set-OS7Service`, `Get-OS7Log`, `Get-OS7InstallLog` | **Done.** `installer/testing/check-service-logic.py`, 15 checks over ten unit states. `check-layering.py` gained a fourth rule, `P2-systemd`, at a baseline of **2** with both remaining sites named. |
| **Scheduled tasks** — OS/7 layer: `Get-OS7ScheduledTask`, `Enable-/Disable-/Start-OS7ScheduledTask`, `Register-/Unregister-OS7ScheduledTask` (P9) | **Done 2026-08-29 — the fix for BUILD-NOTES #113.** `installer/testing/check-scheduledtask-logic.py`, 64 checks over the recorded systemd 259 fixtures, no VM; the same cmdlets run end to end against real systemd as PID 1 in an os7img container (register → run now → the #115 trap → the vendor refusal → unregister, every answer asked back from systemd); and typed at an installed machine for the manual. `Healthy` is `$false` for enabled-and-never-started (#115); disabled tasks stay listed (#116); `Unregister-` refuses non-`os7-task-*` names before any systemd call. P2-systemd still holds at 2. |
| **Management plane** — `Get-OS7EntraStatus`, `Get-OS7IntuneEnrollment`, `Get-OS7ArcStatus`, `Get-OS7ManagementStatus` | **Done, READ only.** `installer/testing/check-management-logic.py`, 25 checks against a real image with systemd as PID 1. Registration (`Register-OS7Entra`, `Register-OS7Intune`, `Connect-OS7Arc`) is **not started**: it needs a tenant and credentials and cannot be checked here at all. |
| The resolver, wireless scan/connect, proxy, hostname | **Not started.** `Get-NetResolver` is deliberately deferred: `resolvectl` needs dbus and could not be measured on the host that built this, and writing a parser for output nobody here has seen is the assertion this project does not make. |
| **Directory** — `powershell/Directory/` and the OS7 layer above it: the admin session, discovery, `Test-OS7Directory`, the user/group/computer/OU surface, the domain join, logon policy, Kerberos tickets | **Done, and checked against a REAL DC** — `installer/testing/check-ad.py` against Samba 4.23.6 in a container, all green; `check-directory-logic.py` 15/15 with no DC and no VM; `Test-DirectoryModule` 40/40. `check-layering.py` gained a fifth rule, `P2-directory`, holding at its baseline of 1 (P8). **The join is code plus a container test: no OS/7 machine has ever joined a domain**, and a real Windows Server DC is owed (open question 7). |
| Everything else in Tiers 1–3 — users, disks and encryption, firewall, inventory, certificates, the capstone, and the rest of Tier 3 (locale, keyboard, power plan, package drift) | **Not started.** |

`Set-OS7NetworkAdapter` **rolls back by default** (decided 2026-08-27). It
writes, applies, then asks `ip` — and when no address appears it restores the
previous document, applies again, and checks that too. Three outcomes, spelled
apart on purpose:

| | meaning |
|---|---|
| `Verified = $true` | the new configuration is up |
| `RolledBack = $true` | it was not, and the old one is back and up |
| `RollbackFailed = $true` | it was not, and **the old one did not come back** — this machine is on neither configuration and may be unreachable |

`-Force` skips the check and therefore the rollback, and leaves `Verified` as
`$null` rather than `$true` — a check that did not run must never read as one
that passed. The case for `-Force` is real: configuring a static address for a
segment the machine is about to be moved to would "fail" verification every
time.

`Test-OS7Network` tests **TCP to the service port, never ICMP**. An enterprise
network that blocks ping and permits HTTPS is ordinary, and testing with ICMP
would report the commonest configuration there is as broken. Its endpoint list
is `powershell/OS7/os7-endpoints.json` — **data, not literals in a cmdlet** —
because Azure Government and 21Vianet do not use `login.microsoftonline.com`,
and a hostname compiled into the cmdlet is wrong for those customers in the way
that reports THEIR network as broken.

`Get-OS7NetworkConfiguration` is the first code in this repository that says
**L28 out loud**: a netplan document matching a MAC or a glob that no adapter on
this machine has is reported as `matches no adapter on this machine`, and
`Agrees` is `$false`. netplan accepts such a document in silence and brings
nothing up, which on a headless machine is a site visit.

Three things were measured while building it that were not known when §1 was
written, and each changed the code:

* **netplan MERGES `/etc/netplan` key by key.** Two documents — one saying
  `dhcp4: true`, a later one saying `dhcp4: false` with an address — produce a
  machine that is Static. A reader that opened `01-os7-network.yaml`, the file
  OS/7 itself writes, would report DHCP for that machine. This is why
  `Get-NetplanConfiguration` asks `netplan get` and reports the file list
  separately as provenance.
* **`netplan get network.renderer` answers `NetworkManager` for a machine with
  no configuration at all** — netplan's own default, and on a headless OS/7
  machine a renderer that is not installed. Hence `RendererIsDefault`.
* **`rfkill -J` exits 1 and still prints a valid, EMPTY device list** when
  `/dev/rfkill` is absent. Hence `Get-NetRadio`'s `Known` flag: "no radio is
  blocked" and "this machine cannot be asked" must not be spelled the same way.

And one trap was paid for twice in one file and is now
[BUILD-NOTES](BUILD-NOTES.md) #92: PowerShell unrolls a single-element array on
return, so `[0]` on a one-line answer indexes into a **string**. It made
`dhcp4: false` read as `$true`. What found it was not review but the self-test's
section guard — the first version of that section threw and the module reported
`36 passed, 0 failed, PASS`.

### What building the clock measured

Three things, each of which changed the code:

* **`chronyc -c` emits CSV**, with fixed field counts — 14 for `tracking`, 10
  for `sources`. The counts are asserted rather than assumed, because a shifted
  field moves a number into `LeapStatus` and the machine then reports itself
  synchronised on the strength of a string comparison.
* **NTP servers do not belong in `chrony.conf`.** They go in
  `/etc/chrony/sources.d/*.sources`, `chronyc reload sources` applies them
  without a restart, and chrony's own README in that directory says both.
  Editing `chrony.conf` is the naive move and is wrong twice: a package upgrade
  owns that file, and a change there does nothing until chronyd restarts.
  `Set-OS7TimeSynchronization` writes `os7.sources` and leaves Ubuntu's pools
  alone unless `-Exclusive` is given.
* **`/etc/timezone` does not exist on this image, and neither does
  `/etc/adjtime`.** The symlink at `/etc/localtime` is the only truth about the
  zone. An absent `/etc/adjtime` means the RTC is UTC — a *default*, so
  `RtcIsDefault` reports it as one rather than as a decision somebody made.

And `Get-OS7TimeSynchronization` has **three** outcomes, not two:
`Synchronised = $null` when chronyd could not be asked at all, `$false` when it
was asked and is not disciplining, `$true` when it is. Returning `$false` for
"no daemon" would send an operator to look at NTP servers on a machine whose
time service is simply not running.

### Remoting is two mechanisms, and they are not the same one

Confusing them is the reason this group has a long note.

| | mechanism | what it makes work |
|---|---|---|
| `InteractiveShell` | `/etc/profile.d/95-os7-powershell.sh` handing an interactive **login shell** over to pwsh (hook 0050) | `ssh os7box` lands at `PS /home/…>` |
| `Subsystem` | `Subsystem powershell /usr/bin/pwsh -sshs -NoLogo` in an sshd drop-in | `Enter-PSSession -HostName os7box` |

**The first already worked and had never been tested.** Measured 2026-08-27
against a real sshd: an interactive login reaches `PS /home/os7admin>`, and with
the drop-in moved aside the same login reaches `logout` in bash. **The second
was simply absent** — `sshd -T` on the shipped image listed `sftp` and nothing
else — so every `Enter-PSSession` failed. `Get-OS7Remoting` reports the two as
separate fields, because an operator who can `ssh` into a box but cannot
`Enter-PSSession` into it needs to be told which half is missing.

**It is not a login-shell change and must not become one.** DECISIONS locks bash
as the system shell — cron, systemd units, dpkg maintainer scripts and Intune's
bash-based compliance scripts all assume it — and pwsh is deliberately absent
from `/etc/shells`. The drop-in gives the lived experience without any of that
breaking, and the check proves the other half of that bargain: `ssh host
'command'` still lands in bash, so scp, sftp, git and rsync are untouched.

`Get-OS7Remoting` answers from **`sshd -T`, not from a file**. `sshd_config`
line 24 already includes a whole directory, and a `Match` block can change the
answer per user — so a file says what somebody wrote and `sshd -T` says what
sshd resolved. Same distinction as P6, applied to a different subsystem.

**No generic `Ssh` module**, and P2's own test is why: sshd has plenty of
vocabulary and OS/7 uses exactly one keyword of it. A module for one keyword
would be P2 applied by reflex, which P2 forbids in the same paragraph.

### What building services and logs measured

`journalctl`'s JSON is structured and **not typed** — every value in it is a
string. `PRIORITY` is `"6"`, `_PID` is `"1"`, and `__REALTIME_TIMESTAMP` is
`"1787839897839138"`, which is **microseconds**. Passing those through leaves
`Where-Object Priority -le 3` comparing text, which succeeds and is wrong. Doing
the typing is most of what `Get-SystemdJournal` is.

Four more, each of which changed the code:

* **`MESSAGE` is an array of bytes when it is not valid UTF-8.** Forced by
  logging `OS7BIN-\xff\xfe-END` into a real journal; it came back as
  `[79,83,55,…]`. A parser assuming a string writes `System.Object[]` into the
  message column of the one line somebody is trying to read.
* **`systemctl show`'s timestamps are localised.** The same unit reported
  `Thu 2026-08-27 14:11:07 UTC` under `TZ=UTC` and
  `Thu 2026-08-27 16:11:07 CEST` under `TZ=Europe/Berlin` — a different hour and
  a different abbreviation. `--timestamp=unix` gives `@1787839867`. A parser
  written against the default works where it was written and is wrong on every
  German desktop, which is this product's market.
* **`_SYSTEMD_UNIT` and `UNIT` are different fields.** The underscore means
  journald added it and the sender could not forge it. `Get-OS7Log -OS7Only`
  filters on the trusted one, because a filter that trusted the sender's field
  could be steered by the thing it is filtering.
* **A health field is wrong about working machines before it is wrong about
  broken ones.** `Healthy` in its first form was `ActiveState -eq 'active'` and
  friends, and on a machine with nothing wrong with it **eight of fifteen** OS/7
  services read as unhealthy — `zfs-mount.service` is a `oneshot`, it had
  succeeded, and `inactive/dead` is what a finished oneshot looks like. `Type` is
  what makes the question answerable. `check-service-logic.py` now enumerates
  the states that must read as healthy as carefully as the ones that must not.

### The management plane says NO, and that is the point

`Get-OS7EntraStatus` on an OS/7 image as built today:

```
AuthdInstalled   : True        authd 0.6.1ubuntu0.1
PamConfigured    : True        pam_authd_exec.so is in the auth stack
ServiceState     : active
BrokerRegistered : False       /etc/authd/brokers.d is EMPTY
Ready            : False
```

Everything looks installed, everything is running, and **a sign-in fails as
though the password were wrong.** That is C8a — `authd-msentraid` is a Canonical
snap and seeding snaps into a live-build image is unsolved — and until this
cmdlet existed there was nothing on a machine that would say so.

Three fields are `$null` on purpose, and each is a decision:

* **`Intune.Enrolled` is `$null` and always will be until something can answer
  it.** `intune-agent`'s entire option set is `--interactive`, `--socket-path`,
  `--help`, `--version` — measured. There is no status verb, and no enrolled
  machine has ever been available to learn the on-disk state from. A guess about
  compliance is the worst possible kind of guess, so the cmdlet carries
  `EnrolledReason` instead.
* **`Arc.Connected` is `$null` when azcmagent is not installed**, because a
  machine that was never connected is not a disconnected machine. The agent's
  absence is deliberate: its `.deb` is staged in `/var/cache/os7/packages/` for
  the installer, since its postinst needs a running systemd and ends in dpkg
  state `iF` inside a live-build chroot.
* **`Entra.Ready` is `$null` when systemd could not be asked at all.** A rescue
  shell is not a broken identity stack.

And `azcmagent show --json` is **passed through unreshaped** when the agent is
present. This repository has never seen that output; typing fields nobody has
measured is the assertion it does not make — the same call `Get-NetRadio` takes
about rfkill's device list.

## 4. Order of work

1. **Network.** Highest value, and the only group with an active drift risk
   (P3) — every day it waits is another day two renderers can diverge.
2. **Time.** Small, and Entra depends on it.
3. **Remoting.** One configuration line, the largest gap between effort and
   perceived completeness.
4. **Services and `Get-OS7Log`.** The object model over `journalctl` is the
   clearest demonstration of why PowerShell is the shell here at all.

---

## 5. Open questions

1. **Is there a firewall on arm64, and should there be one at all?** §1.2
   measured `ufw`/`nftables` present on amd64 and in no package list — they came
   in behind the desktop. arm64 never installs that list. Nothing enables a
   firewall on either. This is a packaging and a product decision before it is a
   cmdlet, and an Intune compliance policy that checks for a host firewall would
   fail an OS/7 machine today.
2. **Does `Rename-OS7Computer` refuse, or warn?** The hostname is registered
   with Entra, Intune and Arc; renaming after enrolment orphans the device
   record. Refusing when enrolled is the safe answer and the annoying one.
3. **`Set-TimeZone` stays unwritten by P1, and that leaves Microsoft's pair
   broken on this platform.** P1 is right about the collision risk and it still
   means an admin finds `Get-TimeZone` and no partner for it. The compatibility
   module of P1 is where this would be resolved, and it is not built yet.
4. **Which module owns systemd**, and whether `Get-OS7Service` is a curated view
   or a rename. P2 says a generic module; the shape of the OS/7 layer above it is
   not designed. *Overtaken in two steps: `powershell/Systemd/` and
   `Get-OS7Service`-as-curated-view exist since §3a's services row, and the
   half this question could not see — where TIMERS live — was decided
   2026-08-29 as P9: a separate noun, not a `-Type` on `Get-OS7Service`.*
5. **Where the secrets go for `Register-OS7Entra` and `Connect-OS7Arc`.** P7 says
   how they are handled in flight; nothing says where a service principal's
   credential rests on an unattended machine.
6. **`os7-endpoints.json` has never been checked against Microsoft's live
   documentation**, and it says so: `verified` is `null` and `Test-OS7Network`
   passes that through rather than swallowing it. CLAUDE.md's rule is that
   anything touching identity gets checked against Microsoft's docs *first*, and
   that check is owed here, per cloud. The four public-cloud hosts were reachable
   when the file was written (measured 2026-08-27, TCP 443, all four), which is
   evidence that they exist and **not** evidence that they are the right or the
   complete set — Intune enrolment in particular is documented as needing more
   than one hostname.
7. **Can an OS/7 machine reach a hardened Active Directory at all, when
   sign-and-seal cannot be switched on from .NET on Linux?** §1.3 measured the
   three walls in a row: `SessionOptions.Sealing` throws, a simple bind on 389 is
   refused outright, and LDAPS on 636 is what is left. That is enough against a
   domain controller with a certificate, and it is nothing at all against one
   without — or against a forest whose policy requires LDAP signing and channel
   binding, which is the configuration Microsoft has spent years pushing
   customers towards. Channel binding has never been exercised here: Samba
   speaks the protocol, it does not reproduce Windows' enforcement of it. The
   answer is owed against a real Windows Server DC, and it decides whether this
   surface works in the enterprises most likely to want it.
8. **Should trusting one domain controller change what every program on the
   machine trusts?** `Add-OS7DirectoryTrust` installs the DC's issuing CA into
   the system store, because §1.3 leaves nowhere else to put it —
   `VerifyServerCertificate` throws, and `LDAPTLS_CACERT` cannot be set from
   inside the process. So the smallest available scope for one administrator's
   LDAPS session is machine-wide, and `curl`, `apt` and Edge inherit it. Whether
   an OS/7 machine should carry an enterprise root CA at all, and whether the
   installer, Intune or this cmdlet is what puts it there, is undecided; what is
   settled is only that the cmdlet reads the store back rather than believing
   `update-ca-certificates`, which exits 0 for a file it skipped.
9. **Is any of this true on arm64?** None of §1.3 was measured there, and the
   packaging half is weaker than it looks: **there is no arm64 packages manifest
   in `out/` at all**, so `libldap2` arriving behind `libcurl4t64` is an argument
   from a dependency rather than a reading of an image. It matters more here than
   elsewhere because the amd64 image had `ldap-utils` and its neighbours *by
   accident* — they came in behind the desktop task that arm64, being
   server-only, never installs. That is the same shape as open question 1, and
   the same single act settles both: an arm64 image measured the way `os7img:116`
   was.
