# Active Directory — administering a domain from a machine that is not in it

**This file is authoritative for how OS/7 reaches Active Directory: what the
admin session is, what the domain join costs, what is deliberately absent, and
what has and has not been run.** Started 2026-08-27. Decisions are A1–An,
limitations AL1–ALn, measurements M-A1–M-An.

It exists because a question from outside the project turned out to have a
different answer from the one everybody assumed:

> "Your tool can only do the new Microsoft online world, right? With an on-prem
> domain — 'I'll just join it to my AD and administer it with my P-users' —
> you don't get far, do you?"

The assumption behind that question is that OS/7's identity story is Entra ID
and that on-prem was traded away. Neither half held up. Entra sign-in **does
not work on any OS/7 image built so far** (C8a: the broker is a snap that
cannot yet be seeded), while the amd64 image has shipped `sssd`, `sssd-ad`,
`libpam-sss`, `libnss-sss` and the OpenLDAP client all along — by accident,
behind the desktop. The on-prem half was materially *further along* than the
online half, and nobody had noticed because nothing had asked.

Related authority: [POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md) P8
for the layer cut, [DECISIONS.md](DECISIONS.md) for what is locked overall,
[SETUP-PLAN.md](../installer/SETUP-PLAN.md) D16/L35 for screen 9D, and
[BUILD-NOTES.md](BUILD-NOTES.md) #94–#96 for the traps this work paid for.
What was actually run, and the defects this work's own tests and its
pre-commit review found, is
[SESSION-ACTIVE-DIRECTORY.md](SESSION-ACTIVE-DIRECTORY.md); the full cmdlet
surface is [POWERSHELL-REFERENCE.md](POWERSHELL-REFERENCE.md). BUILD-NOTES #108
is the one that nearly shipped.

---

## 1. Verdict

**An administrator can sign in to Active Directory from an OS/7 machine with
their own AD admin account, work as themselves, and sign out — and that needs
no domain join, no machine account and no new package.** It is proven against a
real domain controller in a container.

**A domain join is a separate, more expensive feature.** It is written, it
builds, and **no OS/7 machine has ever run it.**

The split between those two sentences is the whole of this document.

---

## 2. The two stages, and why the line is drawn there

| | Stage 1 — the admin session | Stage 2 — the domain join |
|---|---|---|
| What it is | an outbound, credential-based LDAPS connection to a domain controller | a machine account, a keytab, and sssd |
| What it buys | administering AD objects as the operator's own account | domain accounts logging in to *this machine*, sudo by AD group |
| New packages | **none** | `adcli`, `sssd`, `sssd-ad`, `sssd-tools`, `krb5-user` |
| Needs | DNS, a clock within five minutes, the DC's CA trusted | all of that, plus a domain administrator or a pre-created computer account |
| Rolls back badly | no | **yes** — see AL2 |
| Proven | against Samba, in a container, green | never run on a machine |

The line is not arbitrary. Everything on the left is a client making a
connection; everything on the right changes what this machine *is*, and a
machine's identity in a directory is exactly the kind of state D10 moved out of
the boot environment because *the tenant has no rollback*. Stage 2 reintroduces
that problem in a place D10 did not consider (AL2).

---

## 3. What was measured

Taken 2026-08-27 against a Samba 4.23.6 AD domain controller
(`installer/testing/Dockerfile.ad-dc`, realm `OS7.TEST`) and against the
shipped amd64 image `OS7-1.0.0.116-amd64.iso`.

| # | Fact | How |
|---|---|---|
| **M-A1** | `System.DirectoryServices.Protocols.dll` **ships inside PowerShell 7.6.5** and resolves as a bare type literal with **no `Add-Type`**, including under `env -i … pwsh -NoProfile` | `ls` and a type literal in `os7img:116` |
| **M-A2** | It reaches OpenLDAP: a bind to a dead port throws `LdapException`, not `DllNotFoundException`. `libldap2` is a `Depends` of `libcurl4t64`, and `curl` is in `os7-base.list.chroot`, so it is guaranteed on **both** architectures | bind attempt; `dpkg-query` dependency walk |
| **M-A3** | **`System.DirectoryServices` (ADSI) loads and then throws** `"System.DirectoryServices is not supported on this platform."` | `[System.DirectoryServices.DirectoryEntry]::new(…)` |
| **M-A4** | A **simple bind on port 389 is refused**: *"Strong authentication is required for this operation."* LDAPS on 636 binds | both, against the DC |
| **M-A5** | **`SessionOptions.Sealing` and `.Signing` throw** on Linux; their getters return empty. LDAP sign-and-seal is unavailable to this platform | setter attempt |
| **M-A6** | **`SessionOptions.VerifyServerCertificate` throws.** There is no certificate callback; trust is OpenLDAP's | setter attempt |
| **M-A7** | **`ProtocolVersion` reads back `2`.** AD refuses LDAPv2 and the refusal presents as a credential failure | property read on a fresh connection |
| **M-A8** | `ReferralChasing` defaults to `All`, and every search against the domain root returns **three** referrals | property read; `Search-Directory` against `DC=os7,DC=test` |
| **M-A9** | **`AuthType.Negotiate` with an explicitly supplied credential returns LDAP rc 92**, `LDAP_NOT_SUPPORTED`. With an **ambient ticket** it works — but only when krb5's `rdns = false` **and** OpenLDAP's `SASL_NOCANON on` are both set | four binds, with and without each switch |
| **M-A10** | **Setting `$env:LDAPTLS_CACERT` from inside PowerShell does nothing.** .NET on Unix keeps its own copy of the environment and never calls `setenv(3)`, so no native library sees it — while `[Environment]::GetEnvironmentVariable` reads the value back. A real `setenv(3)` works, but only before the first LDAP call in the process | four bind attempts and a P/Invoke |
| **M-A11** | The whole write path works over LDAPS with a supplied credential: create, `unicodePwd`, enable, group membership, paged search, rename, move, delete — **and a bind as the new account with the new password** | `check-ad.py` |

M-A9 and M-A10 are the two that changed the design after it was written down,
and M-A3 is the one that would have cost the most to discover later.

---

## 4. The layer cut

### A1 — the protocol is generic; the domain is policy. Decided 2026-08-27.

`powershell/Directory/` owns LDAP, X.500, the AD schema as *vocabulary*, RFC
4514/4515 escaping, paging, referral policy, what an `LdapException` means, and
realm membership through `adcli`/`kinit`/`getent`. It would run against any LDAP
server on any Ubuntu host and contains no `OS7`-prefixed name.

`powershell/OS7/OS7.Directory*.ps1` and `OS7.Domain.ps1` own which server, which
groups, the five-minute Kerberos rule, what `Ready` means, and every cmdlet an
operator types. This is POWERSHELL-SURFACE-PLAN P2 applied, and P8 is the
decision in its own file.

`check-layering.py`'s **P2-directory** rule holds it: `powershell/OS7` may not
name `ldapsearch`, `kinit`, `klist`, `adcli`, `realm`, `sssctl` or `getent`.
Baseline **1**, and the one is named rather than left to be found —
`OS7.Home.ps1:122` asks `getent` about a *local* account and predates the rule.

### A2 — TLS is the default and port 389 is opt-in. Decided 2026-08-27.

Forced by M-A4 and M-A5 together: the platform cannot sign a bind, and a
domain configured to Microsoft's own ADV190023 guidance refuses an unsigned
one. `-AllowUnencrypted` exists for a laboratory and says what it is doing.

---

## 5. The session model

### A3 — the credential is used and then forgotten. Decided 2026-08-27.

`Enter-OS7AdminSession` binds and keeps the *bound connection*. The password is
not retained, so the session cannot silently re-authenticate — which is the
point: a session that could would be a password at rest. `check-ad.py` asserts
with a canary that the session object carries no password into JSON.

### A4 — the identity reported is the SERVER's answer, not the name typed in.

A bind that raises no exception is not proof of identity; it is proof that no
exception was raised. `Enter-OS7AdminSession` asks the directory *"who am I"*
(RFC 4532) and refuses the session if the server will not say — which is also
what catches a bind that quietly fell back to anonymous.

### A5 — administration runs UNELEVATED; machine operations run elevated.

sssd's default credential cache is in the kernel keyring, which is scoped to a
uid, so an elevated shell cannot see the ticket the unelevated one holds and
`sudo -E` does not change that. Two contexts in one session, and the surface
says so rather than letting an operator meet it as an access-denied from the
directory. `New-OS7KerberosTicket`'s help carries the warning.

### A6 — there is always a way past the curated surface.

`Search-OS7AD`, `Get-OS7ADObject` and `Set-OS7ADObject` take raw filters, DNs
and attribute names. A curated directory surface that cannot be escaped has to
be complete, and no directory surface ever is.

---

## 6. The join

### A7 — `adcli`, not `realmd`. Decided 2026-08-27.

`realmd` is a D-Bus service that wants to configure a running system and is
awkward to drive against a chroot; `adcli` is a one-shot program that performs
the join and writes the keytab — the one piece that cannot be written by hand.
OS/7 writes `sssd.conf` itself, because its contents are policy (A9). This also
drops `realmd` from the package list entirely.

### A8 — the join happens during the install, not on first boot.

The opposite of the TPM case (#69), and for a reason that does not transfer:
TPM sealing depends on PCR values that differ between the installer and the
installed system, while a join depends on hostname, DNS, time and a credential,
which are the same in both. Joining on first boot would mean *storing the
credential between install and boot*, which P7 forbids. Screen 9D therefore
collects it, `DomainStep` uses it, and it never reaches disk.

The road a fleet should take is a **pre-created computer account with a one-time
password**, so no domain administrator credential is typed into a text-mode
installer at all.

### A9 — domain users' homes go outside the boot environment.

`sssd.conf` is generated with `fallback_homedir = /var/lib/os7/domain-homes/%u`.
Without it, `pam_mkhomedir` — which is already in this image's `common-session`
— creates them inside the boot environment, where `Restore-OS7` rolls them back
with the operating system. That is BUILD-NOTES #74 in a second location, and
this repository has already paid for it once.

### A10 — a sudoers rule is checked by `visudo` before it counts.

A space in a group name (`Domain Admins`) written unescaped is a syntax error,
and a syntax error anywhere in `/etc/sudoers.d` makes sudo refuse **every** rule
in the file — including the one that lets the local break-glass account become
root. `Set-OS7DomainLogonPolicy` stages the file, runs `visudo -c` against it,
and moves it into place only if that passes.

---

## 7. Test strategy

### A11 — two tiers, and the second one is a real directory.

| Tier | What | Cost | State |
|---|---|---|---|
| 1 | `Test-DirectoryModule` — escaping, conversions, flag decoding, error meanings, the sssd document | seconds, in-process | **40/40** |
| 1 | `check-directory-logic.py` — the *decisions*, against a fake connection: which filter, which modify operation, whether a value is read before one bit is changed, what bytes a password becomes | seconds, no network | **15/15** |
| 2 | `check-ad.py` — a real Samba AD DC in a container, with `ldbsearch` as the independent witness | ~2 minutes | **all green** |
| 3 | a real **Windows Server** domain controller | not built | **owed** |

Faking an LDAP server would have tested only the fake. The behaviours that
decided this design — a refused simple bind, a paged search, three referrals, a
password write over TLS — are exactly the ones nobody would think to write into
a stub.

`check-ad.py` also proves the thing no other check can: it runs the stage-1
section a second time with `adcli`, `kinit`, `klist` and `sssctl` **moved out of
PATH**, so "stage 1 needs none of stage 2's packages" is demonstrated rather
than asserted.

---

## 8. What OS/7 deliberately does not do

| | Why |
|---|---|
| **Group Policy** — authoring, editing, linking | No GPO engine exists for Linux. sssd can *enforce* logon-right GPOs, which is consumption, not administration |
| Anything over **RPC/DCOM**: `repadmin`, `dcdiag`, `netdom`, DNS server, DHCP, certificate enrolment | no cross-platform client exists |
| Anything through **`[ADSI]`** | M-A3: it loads and then throws. A Windows script using it does not port by copying |
| **WinRM** / `New-PSSession -ComputerName` | measured dead on Linux: *"no supported WSMan client library was found"* |
| **RSAT GUIs** (ADUC, ADAC, GPMC) | Windows only. `Enter-PSSession -HostName` to a Windows admin host is the documented route, and it is PowerShell's own — P4 says what already works is not rebuilt |
| **Making a joined machine Intune-manageable** | enrolment goes through Entra ID; there is no hybrid join for Linux |

---

## 9. Limitations — the honest list

| | |
|---|---|
| **AL1** | **No OS/7 machine has ever joined a domain.** `Join-OS7Domain` and screen 9D are code that compiles and passes a self-test. `check-ad.py` joins a *container* to a *Samba* domain; that is the protocol, not a fleet. |
| **AL2** | **A boot-environment rollback breaks the machine account, and nothing else in this repository has this shape.** `/etc` lives inside the boot environment, so `/etc/krb5.keytab` does too, while sssd's cache under `/var/lib/sss` sits outside it (D10). An AD machine password rotates every 30 days by default: roll back, and the machine holds a credential the domain controller has moved past, authenticates nobody, and reports nothing. `Repair-OS7Domain` renews it and `Test-OS7Domain` notices — but whether the *layout* should change is open. It is D10's own argument arriving from the mirror image, and D10 did not consider it. |
| **AL3** | **Samba is not Windows Server.** Not reproduced here: LDAP channel binding and signing enforcement, Windows password-policy plumbing and its error sub-codes, `msDS-*` constructed attributes, Windows LAPS, cross-forest referrals. A green `check-ad.py` is the gate for the protocol only. |
| **AL4** | **Certificate trust is machine-wide and cannot be scoped to a session** (M-A6, M-A10). `Add-OS7DirectoryTrust` installs a CA into the system store and reads back that it took. There is no per-call option and no way to build one on this platform. |
| **AL5** | **Kerberos single sign-on needs two configuration files nobody writes yet.** M-A9: the ambient-ticket path works only with `rdns = false` in `krb5.conf` and `SASL_NOCANON on` in `ldap.conf`. Neither file exists on an OS/7 image, and `krb5-user` is a stage-2 package. Stage 1 is deliberately password-based. |
| **AL6** | **`powershell/Directory/` is unpoliced by construction.** `check-layering.py`'s walk root is `powershell/OS7` only, so nothing stops the Directory module from shelling out to `resolvectl` or `systemctl`. That is true of `Net`, `Time` and `Systemd` too; the only defence is the file's own header, which says so. |
| **AL7** | **arm64 is entirely unmeasured.** There is no arm64 packages manifest in `out/` at all. The three packages this work adds to `os7-base.list.chroot` are named precisely because they are on amd64 *by accident* and absent from arm64 by construction — but no arm64 image has been built since. |
| **AL9** | **`Get-DirectoryAttributeValues` does not keep its own promise unless the caller wraps it.** Its contract says "always an array"; `return @($value)` is unrolled by the pipeline on the way out, so a bare `$v = Get-DirectoryAttributeValues …` on a one-value attribute is a `String` and `$v[0]` is a character — BUILD-NOTES #92 inside the function documented as its guard. It is latent: all eleven call sites wrap in `@(...)` and are correct. The obvious remedy, `return ,$value`, was written and MEASURED to break every one of those sites in the other direction (a one-element result becomes a nested array, and `MemberCount` reads 1 for a group of three). Neither spelling is safe for both call styles, so the migration is one commit that changes the function and all eleven sites together, and it has not been made. |
| **AL10** | **A group with more than 1500 members reads as empty.** Active Directory range-limits the `member` attribute and returns it as `member;range=0-1499`; `member` itself is then absent, so `MemberCount` is 0, `Member` is empty and `Get-OS7ADGroupMember` returns nothing — with no error. This is a different mechanism from the paged search the module does implement, and no laboratory domain reaches it. |
| **AL11** | **`LockedOut` reports accounts that have already unlocked themselves.** It is read from `lockoutTime` being non-zero, which is right about the lockout and wrong about its expiry: AD leaves the value in place after the lockout duration passes and the account works again. A correct answer needs the domain's `lockoutDuration`, which means a second query the cmdlet does not make. |
| **AL8** | **The single-DC case is the only one exercised.** `Resolve-NetSrvRecord` sorts by priority and weight and its fixtures contain a multi-record answer, but no run has ever seen a domain with two controllers, a site topology, or a controller that stops answering mid-session. |

---

## 10. Open questions

1. **Should `/etc/krb5.keytab` leave the boot environment?** AL2. Moving part
   of `/etc` out is precisely the split L21 warns about, and the alternative —
   detect and repair — is what is built. This needs deciding before a fleet, not
   after.
2. **Do domain users' homes need per-user ZFS datasets?** A9 puts them on one
   dataset outside the boot environment, which solves the rollback problem. It
   does not give them the per-user snapshot boundary that local accounts get
   from `rpool/USERDATA/<user>_<uuid>`. Whether that matters is a backup-policy
   question (BACKUP-PLAN) as much as an identity one.
3. **Where does a Windows Server domain controller come from?** AL3 is the
   largest untested surface. A session working on the VM-harness port in a
   separate worktree is building KVM-in-docker plumbing that derives
   machine/accel/firmware in one place with serial and QMP reachable from
   outside the container; that is the layer a Windows-DC harness would need.
   Licensing and an unattended install are the remaining problems.
4. **Does the join belong in the installer at all?** A8 argues yes on
   credential-handling grounds. The counter-argument is AL1: screen 9D is the
   only part of this work that cannot be tested without building an ISO and
   running an install, and it is the part least likely to be used by the fleets
   that would take the one-time-password road anyway.

---

## 11. What was verified, and how

```
Test-DirectoryModule                     PASS  (throws on failure, since #108's review)
check-installer-cmdlets.py               green, and RED against the known defect
Test-NetModule                           PASS  (with the SRV cases)
check-directory-logic.py                 15/15, no network
check-ad.py                              all green against Samba 4.23.6
check-layering.py                        5 rules held; P2-directory at baseline 1
os7-setup --self-test                    clean (the 10 failures are absent image files)
```

**Not verified:** no ISO has been built since any of this landed, so the build
staging, hook 0060's new checks and the three added packages have not been
through `make build-amd64`. Screen 9D has never been drawn on a machine.
`Join-OS7Domain` has never run outside a container. arm64 has not been measured
at all.
