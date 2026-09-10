# Session — Active Directory, and a premise that was wrong in both directions

**Measured 2026-08-27 and 2026-08-28.** Against `main` at `8700095`, the shipped
amd64 image `OS7-1.0.0.116-amd64.iso` / `os7img:116`, and a Samba 4.23.6 Active
Directory domain controller built for this session
(`installer/testing/Dockerfile.ad-dc`, realm `OS7.TEST`).

It started as a question from outside the project, forwarded without comment:

> "Your tool can only do the new Microsoft online world, right? With an on-prem
> domain — 'I'll just join it to my AD and administer it with my P-users' — you
> don't get far, do you?"

The honest answer needed a measurement rather than an opinion, and the
measurement went the other way twice.

---

## 1. The premise, and both halves of why it was wrong

**The assumption:** OS/7's identity story is Entra ID, and on-prem Active
Directory was traded away for it.

**What the image actually had.** Read out of the shipped amd64 manifest and out
of `os7img:116`:

```
/etc/nsswitch.conf     passwd: files systemd sss authd
/etc/pam.d/common-auth pam_authd_exec.so, then pam_sss.so
/etc/pam.d/common-session pam_sss.so, pam_mkhomedir.so
installed              sssd 2.12.0, sssd-ad, sssd-krb5, sssd-ldap,
                       libpam-sss, libnss-sss, ldap-utils, libsasl2-modules-gssapi-mit
absent                 realm, adcli, kinit, klist, sssctl
```

So the login stack was **already wired for a directory** and only the join
tooling was missing — while Entra sign-in, the headline feature, **cannot work
on any OS/7 image built so far**, because its broker is a Canonical snap that
cannot yet be seeded (C8a, and `Get-OS7EntraStatus` reports it). The on-prem
half was materially further along than the online half, and nobody had noticed
because nothing had asked.

**And the second half of the correction:** none of that arrived by decision. No
OS/7 package list names `sssd`. It came in behind `ubuntu-desktop-minimal`,
which means arm64 — server-only, never installs that list — has none of it, and
the amd64 headless path purges the desktop and then runs `apt-get autoremove
--purge`, which takes anything that got there as a dependency. The feature
existed on one of three products, by accident.

---

## 2. The measurements that decided the design

Eleven, in `docs/AD-PLAN.md` §3 with their provenance. The four that changed
what was built:

**M-A1/M-A3 — one foundation and one trap, indistinguishable from the
documentation.** `System.DirectoryServices.Protocols` ships *inside* PowerShell
7.6.5 on Linux, resolves as a bare type literal with no `Add-Type`, and reaches
`libldap.so.2`. `System.DirectoryServices` — ADSI, which every Windows AD script
uses — loads and then throws `"System.DirectoryServices is not supported on this
platform."` An assembly that loads is not a subsystem that runs, and only a bind
attempt separates them.

**M-A9 — the elegant design does not work.** The obvious shape for "administer
AD as yourself" is a Kerberos bind with the operator's credential.
`AuthType.Negotiate` with an explicitly supplied credential returns **LDAP rc
92, `LDAP_NOT_SUPPORTED`**, on this platform. With an *ambient* ticket it works
— and only then with two independent switches set:

```
krb5.conf   rdns = false          (MIT Kerberos canonicalises via reverse DNS)
ldap.conf   SASL_NOCANON on       (OpenLDAP canonicalises again, separately)
```

Fixing the first changed nothing: the error stayed identical, character for
character, while `kvno ldap/dc01.os7.test` had already been issuing service
tickets successfully. Two layers, one symptom. Anyone debugging this repairs one
and concludes Kerberos is broken.

**M-A4/M-A5 — TLS is not a preference.** A simple bind on port 389 is refused by
the directory (*"Strong authentication is required for this operation"*), and
`SessionOptions.Sealing` **throws** on Linux, so the connection cannot be signed
instead. LDAPS on 636 is the only credential path this platform has. That is why
`A2` makes TLS the default and port 389 opt-in, rather than the other way round.

**M-A10 — a setting that reads back correctly and does nothing.** Certificate
trust is OpenLDAP's, because `SessionOptions.VerifyServerCertificate` throws
too. The one mechanism that could have scoped it to a process — the
`LDAPTLS_CACERT` environment variable — **cannot be set from inside PowerShell
at all**: .NET on Unix keeps its own copy of the environment and never calls
`setenv(3)`, so no native library ever sees it, while
`[Environment]::GetEnvironmentVariable` returns the value happily. A real
`setenv(3)` through P/Invoke works, but only before the first LDAP call in the
process, because OpenLDAP reads its environment once.

The failure this produces is `"The LDAP server is unavailable."` — pointing at
the network for a problem that is trust. `Connect-DirectoryServer` now refuses
to pass that message on unimproved.

---

## 3. What was built

**Stage 1 — the admin session. No domain join, no machine account, no new
package.** An administrator signs in to the directory *from* an OS/7 machine
with their own AD admin account, works as themselves — so the domain
controller's audit trail names a person and no credential rests on the machine —
and signs out.

**Stage 2 — the domain join.** `Join-OS7Domain`, `Repair-OS7Domain`, the logon
policy, the Kerberos ticket verbs, and installer screen 9D. Five packages.

The layer cut is P8: `powershell/Directory/` owns the protocol and realm
membership and would run on any Ubuntu host; `powershell/OS7/` owns which
domain, which groups, the five-minute Kerberos rule and every `OS7`-prefixed
name. `check-layering.py` gained a fifth rule, **P2-directory**, at baseline 1 —
the one existing site being a `getent` call in `OS7.Home.ps1` that asks about a
*local* account and predates the rule.

Full surface: [POWERSHELL-REFERENCE.md](POWERSHELL-REFERENCE.md). Reasoning and
decisions A1–A11: [AD-PLAN.md](AD-PLAN.md).

---

## 4. The test fixture, and two things it cost before it ran

`installer/testing/Dockerfile.ad-dc` is a real Samba AD domain controller in a
container: local, free, offline, reproducible — the same constraints as every
other harness here. It cost two measurements to stand up, both now in the
Dockerfile's header:

* **The AD DC role is not in the `samba` package on Ubuntu 26.04.** It is in
  `samba-ad-dc` + `samba-ad-provision`, and `samba-tool` comes from
  `python3-samba`, which is only a `Suggests`. `apt-get install
  --no-install-recommends samba` yields a file server whose `samba-tool` is
  absent, and the failure is at run time in a container that built green.
* **Provisioning needs `posix:eadb`.** SYSVOL's `security.NTACL` extended
  attribute needs `CAP_SYS_ADMIN`, which Docker drops; this Samba no longer
  offers `--use-xattrs=no`. The alternative is `--privileged`, and a harness
  that needs a privileged container is a harness people stop running.

---

## 5. The defects, and where each was caught

Five were found by the work's own tests as it was written. The rest were found
by an adversarial review of the whole change, run deliberately BEFORE the
commit, and section 6 is about that.

| found by | defect |
|---|---|
| `Test-DirectoryModule` | **#94** — `[datetime]::TryParseExact` handed a plain PowerShell `@(...)` binds to the *single*-format overload and joins the array into one format string. No type error, no exception: every timestamp comes back `$null`, which reads as "this DC does not send `whenCreated`" |
| a deliberately wrong password against the DC | **#95** — `catch [LdapException]` matches the inner exception, but `$_.Exception` inside the handler is still the wrapper. Reading `.ErrorCode` off it throws a property error *inside the handler that was supposed to explain the failure* |
| `check-directory-logic.py`, eleven identical failures | **#96** — `.GetNewClosure()` breaks a test seam that must reach module state. The other checks replace a *command runner* and must carry local values in, which is what it is for; this one must reach *module* state, and the closure rebinds `$script:` away from it |
| generating the function reference | **eleven functions were unreachable.** The module exported 36 and the manifest listed 25 — the whole realm half. The module loads cleanly, every other check passes, and `Join-OS7Domain` would have failed on a machine, during an install, with *"the term 'Join-DirectoryRealm' is not recognized"*. Two export filters, one moved. Nothing in the repository compared them; `Test-DirectoryModule` now does |
| the author of #94, tracing his own entry's consequence | **`Test-OS7Directory` reported `Ready` when the clock could not be checked.** The line read `($clockOk -ne $false)`, which is true for `$null`. "Cannot tell" had been written as "fine" in the one check that decides whether Kerberos will work |

The last two are the argument for the whole exercise: both were invisible to
every green check, and both would have surfaced on a customer's machine.

---

## 6. The pre-commit review, and the one that would have shipped

The change was complete, every check was green, and it was about to be pushed.
Three reviewers were pointed at it instead, told to be adversarial, and given
the measurements so that a contradiction of one would itself be a finding. The
riskiest slice was the C# installer, because the agent that wrote it had hit a
session limit before reporting and nobody had read it.

**Two reviewers, independently, found the same thing.** `Steps/DomainSteps.cs`
built `Join-OS7Domain -Root '<target>' … -PasswordFile '<file>'`, and the cmdlet
declares `-TargetRoot` and `-Password`. Every domain join from the installer
would have failed at **parameter binding** — before `adcli` was ever started —
and the step's deliberate best-effort handling would have reduced it to one line
in a log.

What was green while that was true: `dotnet publish`, `os7-setup --self-test`,
five module self-tests, `check-directory-logic.py`, `check-layering.py`,
`check-ps-traps.py`, and `check-ad.py` **against a real domain controller,
including a join**. Every one of them exercises one side of the seam; nothing in
this repository had ever read the installer's generated command lines. That is
BUILD-NOTES #108, and the guard is a new check that reads the C# for what will
be typed and asks PowerShell what will bind.

The rest of what the review found, all confirmed by reading the code:

| | |
|---|---|
| `Test-DirectoryModule` **could not report failure** — every line went to `Write-Output`, so the return value was a truthy array and the process exited 0 whatever happened. `check-image.py` gates on `EXIT=0`. A broken Directory module would have shipped a green ISO |
| The generated `sssd.conf` was **fail-open**: `access_provider = simple` with no allow list grants every domain user access |
| `--host-keytab` was never passed to `adcli`, so a join against a target root wrote the machine credential to the **live** `/etc/krb5.keytab` and then reported `Joined = $false` for a join that worked |
| `Test-OS7Domain.Healthy` read "cannot tell" as "clean" — the same defect already fixed in its sibling an hour earlier, in the function whose own docstring forbids it |
| `Get-SystemdUnit -Name 'sssd'` never matches `sssd.service`, so `SssdRunning` was permanently `$null`. The write path hides it: `Restart-SystemdUnit -Name 'sssd'` works, because `systemctl restart` mangles a bare name and `list-units` does not |
| `--domain-password-file` was parsed and discarded, so an unattended install with a join was refused **entirely** |
| The best-effort `catch` caught only `StepException`, so an `IOException` from the keyfile write would have escaped into the executor's rollback — a `zpool destroy` on an install complete through the bootloader |
| Screen 9D was **absent from the self-test's screen array**, so nothing had ever checked that it draws (found separately, while tracing reachability) |

**One finding was confirmed and deliberately not fixed**, which is worth as much
as the fixes. `Get-DirectoryAttributeValues` really is BUILD-NOTES #92 inside the
function documented as its guard. The obvious remedy — `return ,$value` — was
written, and the module's own existing cases went red: it breaks all eleven call
sites in the other direction, because a one-element result becomes a nested
array and a group of three reads `MemberCount = 1`. Neither spelling is safe for
both call styles. It is latent today because every caller wraps in `@(...)`, and
it is written down as AL9 with the migration it needs, rather than half-made.

The lesson is not that review finds bugs. It is **which** bugs: every one of
these survived a suite that was green, and the two worst were in the seams
between things that were each individually tested.

---

## 7. What this changes in the plans

* **New:** [AD-PLAN.md](AD-PLAN.md) — authoritative for A1–A11, AL1–AL8, M-A1–M-A11.
* **New:** [POWERSHELL-REFERENCE.md](POWERSHELL-REFERENCE.md) — all 185 functions,
  generated by asking the modules.
* **POWERSHELL-SURFACE-PLAN:** P8, a Directory tier row, the LDAP measurements
  beside the existing §1 findings, and three new open questions.
* **SETUP-PLAN:** D16 (the join happens *during* the install, `adcli` not
  `realmd`, one-time password preferred) and L35 (what screen 9D cannot do yet).
  Both numbers had been cited by three C# files for a day with no row in either
  table.
* **DECISIONS:** one locked bullet, and two open questions — the keytab-versus-
  boot-environment interaction, and whether domain users' homes need per-user
  datasets.
* **BUILD-NOTES:** #94, #95, #96, and the counter line, which had said "above 81
  are free" since #82.
* **`os7-base.list.chroot`:** `ldap-utils`, `libsasl2-modules-gssapi-mit`,
  `bind9-dnsutils` for stage 1; `adcli`, `sssd`, `sssd-ad`, `sssd-tools`,
  `krb5-user` for stage 2. Naming them is what makes the feature exist on arm64
  and on amd64-headless at all. **This changes `packages.manifest` on both
  architectures — a deliberate change of spike S7's baseline, not drift.**
* **A pre-existing packaging defect fixed on the way:** the `os7-module` .deb
  carried only `Zfs` and `OS7`. `Net`, `Time` and `Systemd` were staged into the
  ISO and were not in the package, so on an apt-installed machine every
  `Import-OS7*Layer` fell through to `Import-Module <Name>` and threw.
  `check-os7-repo.py` asserts the package is installed at the right version and
  never what is inside it.

---

## 8. What was NOT measured

Stated plainly, because "cannot tell" is not "clean":

* **No OS/7 machine has ever joined a domain.** `check-ad.py` joins a *container*
  to a *Samba* domain.
* **No ISO has been built since any of this landed.** The build staging, hook
  0060's extended checks and the eight added packages have not been through
  `make build-amd64`.
* **Screen 9D has never been drawn on a machine.** It compiles, it renders in
  `--self-test`, and `run-phase3.py` — which would walk it — needs the Apple
  Silicon host.
* **arm64 is entirely unmeasured.** There is no arm64 packages manifest in
  `out/` at all, and the three stage-1 packages were added precisely because
  arm64 is believed not to have them.
* **Windows Server is untested, and Samba cannot stand in for it.** Not
  reproduced by Samba: LDAP channel binding, signing enforcement, Windows
  password-policy sub-codes, `msDS-*` constructed attributes, LAPS, cross-forest
  referrals.
* **Kerberos SSO is unexercised end to end.** M-A9 measured that the ambient-
  ticket path works; nothing on an OS/7 image writes the two configuration files
  it needs.
* **One domain controller, one domain, twenty objects.** No site topology, no
  second DC, no controller that stops answering mid-session, and no result large
  enough to meet AD's real 1000-object page limit — the paging loop was exercised
  by forcing a page size of two.
