# Session: the domain join, on a machine, against Windows Server

**Date:** 2026-09-07 · **Host:** x64 Windows 11 + Hyper-V (the test DC) + os7lab bench `gui` (amd64, KVM in Docker) · **Image:** 1.0.0.163

`Join-OS7Domain` had never run. This session ran it against the real Windows Server 2025
domain controller from [SESSION-AD-REAL-DC.md](SESSION-AD-REAL-DC.md), end to end, and it
works — after one thing that had to be added, and one defect that had to be fixed. Three
statements in AD-PLAN.md turned out to be false, and one of its decisions turns out not to be
achieved by the product at all.

## What ran, and what each thing proves

Bench `gui` restored to snapshot `ad-trusted`, DNS pointed at the domain controller
(`resolvectl`, because SRV discovery is how adcli and sssd find a DC and QEMU's resolver knows
nothing about `os7test.local`). Scripts and raw output in the session scratchpad
(`os7dc/os7-join-stage2.ps1`, `os7-join-verify.ps1`, `os7-leave-then-rejoin.ps1`, `.out` beside
each). End state: snapshot **`domain-joined`** on bench `gui`.

| step | result |
|---|---|
| `Get-OS7Domain` / `Test-OS7Domain` **before** | `Joined=False`, `Healthy=False`, and the Detail names the missing `sssd.conf`. The control that makes the rest mean something |
| `Join-OS7Domain` on adcli's **default** path | **fails**, see below |
| `Join-OS7Domain -UseLdapPassword` | `Joined=True`; keytab holds `OS7-GUI$`, `host/OS7-GUI`, `RestrictedKrbHost/OS7-GUI` at kvno 3 |
| the keytab, **used** rather than stat-ed | `kinit -k -t /etc/krb5.keytab OS7-GUI$@OS7TEST.LOCAL` returns a TGT. The machine credential works, which a file of the right name does not prove |
| `sssd.conf` | `fallback_homedir = /var/lib/os7/domain-homes/%u`, `simple_allow_groups = OS7-Testers`, `use_fully_qualified_names = False`, mode 640 root:sssd (never world-readable) |
| sssd | `active`, and `sssctl domain-status` reports it connected to `os7-dc01.os7test.local` |
| name resolution — the only thing that proves a join | `getent passwd t.user1` → uid 1856801103, home `/var/lib/os7/domain-homes/t.user1`; `id` shows `domain users` and `os7-testers`; `getent group OS7-Testers` lists all five test users |
| `Test-OS7Domain -ProbeAccount t.user1` | `Healthy=True`, skew 2.3 s. Its only remaining Detail is the standing note that a join does not make the machine Intune-manageable |
| a real password authentication | `New-OS7KerberosTicket -Principal t.user1@OS7TEST.LOCAL -Credential …` → TGT from the real KDC |
| **the allow list**, A9's fail-closed decision | `sssctl user-checks t.user1 -a acct` → `pam_acct_mgmt: Success`; `Administrator`, who is in no allowed group → `Permission denied`. Enforced, on a real DC |
| **A10**, the sudoers rule | `/etc/sudoers.d/60-os7-domain-admins` contains `%Domain\ Admins ALL=(ALL:ALL) ALL`, the space escaped, and `visudo -c` says `parsed OK` |
| a domain user's home | created at `/var/lib/os7/domain-homes/t.user1`, owned `t.user1:domain users`, and `su - t.user1` lands in it |
| `Remove-OS7Domain` | `ComputerAccountRemoved=True`, `KeytabRemoved=True`; keytab and `sssd.conf` gone, `Joined=False` |
| the same call with the account already deleted | `ComputerAccountRemoved=False` and the Detail says why. It does not claim to have removed what was not there |

**The independent witness.** Everything above is the machine's own account of itself, so the
domain controller was asked separately, with Microsoft's own tooling:

```
CN=OS7-GUI,OU=OS7Test,DC=os7test,DC=local   Enabled: True
dNSHostName: os7-gui        operatingSystem: pc-linux-gnu
SPNs: RestrictedKrbHost/OS7-GUI; host/OS7-GUI
msDS-SupportedEncryptionTypes: 24   (AES128 + AES256, no RC4)
whenCreated 12:03:27        lastLogon 12:03:28
```

`-OrganizationalUnit` was honoured. And `lastLogon` one second after `whenCreated` is the
strongest fact in this document: the machine did not merely acquire an account, it
**authenticated with it**.

## What the join needed and nobody had written down

    adcli: joining domain os7test.local failed:
    Couldn't set password for computer account: OS7-GUI$: Message stream modified

adcli sets the computer account's password through the **Kerberos set-password service**
(kpasswd, RFC 3244) by default. That exchange is integrity-protected over the addresses each end
sees. This machine reaches the domain controller through QEMU's user-mode NAT — it believes it
is `10.0.2.15`, the DC sees the host's LAN address — so the checksum fails and what surfaces is
a sentence about a byte stream.

`adcli --ldap-passwd` sets the password with an **LDAP modify of `unicodePwd`** over the
GSS-SPNEGO connection adcli has already sealed, and the same join then succeeds with nothing
else changed. Measured both ways, twice each.

**OS/7 could not express it.** `Join-DirectoryRealm` had no way to pass that option, so a
machine behind NAT could not be joined by the product at all — only by dropping to `adcli` by
hand. Added: `-UseLdapPassword` on `Join-DirectoryRealm` and on `Join-OS7Domain`, opt-in,
leaving adcli's default alone — one measurement in one network is not a reason to change what
every other machine already does. What is NOT left to chance is the diagnosis: the failure is
now translated and **names the switch**, so nobody has to know this in advance. It also warns
that the computer account has already been created by the failed attempt, because adcli creates
the object before it sets the password — measured: `CN=OS7-GUI` was in the directory, enabled,
with SPNs, after a join that had reported failure.

`-UseLdapPassword` is **not reachable from the installer.** Screen 9D calls `Join-OS7Domain`
and has no field for it, so a machine that needs it cannot be joined during setup. Open.

## The defect: a parameter that never bound, in the one path that had never run

```
OS7-STEP sssd could not be started here: A parameter cannot be found that matches parameter name 'Enabled'.
```

`Join-OS7Domain` called `Set-SystemdUnitStartup -Name 'sssd' -Enabled`. That cmdlet takes
`-Startup` with a `ValidateSet` of `Enabled`/`Disabled`/`Masked`; there is no `-Enabled`. The
binding error was caught by the surrounding `try` and degraded to one warning line among
several, and **on this image sssd ships enabled**, so the machine looked correctly configured
and nothing else showed it. On an image where sssd is not already enabled, the join would leave
it un-enabled and the machine would drop out of the domain at the next boot.

Every other caller of that cmdlet in the repository — `OS7.ScheduledTask.ps1` three times,
`OS7.Service.ps1` once — already used `-Startup` correctly. The wrong one was in the only
function that had never been executed, which is the whole argument of this session.

Fixed, and verified with a control that gives the fix something to prove: sssd was
**deliberately disabled** before the join, and after it reads `enabled` / `active`.

**The check gap this leaves — now closed.** `check-installer-cmdlets.py` catches exactly this
class, a caller naming a parameter the callee does not have, but only for what the C# installer
types (#108). Nothing looked at PowerShell calling PowerShell, which is 194 functions calling
each other. `check-ps-traps.py` has a sixth rule for it (**#127**): for every call to a function
the tree DEFINES, each `-Parameter` must resolve to one that function declares, allowing
PowerShell's own unambiguous-prefix rule and the common parameters, and skipping a call that
splats or a callee with a `dynamicparam` block — in each of those the source does not carry the
answer.

It was **verified in both directions**, because a scan that has only ever been pointed at a
clean tree has been proven to stay quiet and never proven to speak:

- the real defect was re-introduced into a throwaway copy of `powershell/`, and the rule named
  it: `OS7.Domain.ps1:208  Set-SystemdUnitStartup -Enabled  (no such parameter)`, exit 1;
- the same call written as `-Start Enabled` — a legal unambiguous prefix — was **not** reported,
  which is the false-positive case that would get the rule deleted.

`OS7_SCAN_ROOT` is honoured if already set, which is what makes that possible; the scan reports
0 across all 22 files today.

## AD-PLAN was wrong in three places, and one decision is not achieved

1. **AL1 said `check-ad.py` "joins a container to a Samba domain".** It does not, and never
   did: no `Join-DirectoryRealm`, no `adcli`, no keytab anywhere in that file. Its own header
   sentence listed "join a realm" among what it drives. So Stage 2 had never run **anywhere,
   against anything** — not against Windows, and not against Samba either. Both sentences are
   corrected.
2. **AL2 said sssd's cache under `/var/lib/sss` "sits outside" the boot environment (D10).**
   Measured: `/var`, `/var/lib`, `/var/lib/sss` and `/var/lib/os7` are all
   `rpool/ROOT/<be>`. The datasets outside are `rpool/DATA/{log,spool,tmp,srv,lib/authd,lib/snapd,lib/networkmanager}`
   and `rpool/USERDATA/*`. The rollback hazard is real but differently shaped: a `Restore-OS7`
   takes the keytab, the sssd cache **and every domain user's home** back together.
3. **AL5 said neither `krb5.conf` nor `ldap.conf` exists on an OS/7 image.** `/etc/krb5.conf`
   does exist — `krb5-user` ships MIT's example, with `ATHENA.MIT.EDU`, `stanford.edu` and
   `default_realm = LOCALHOST.LOCALDOMAIN`. It already sets `rdns = false`. A stock file naming
   a realm that does not exist is arguably worse than no file: a bare `kinit` reports "Cannot
   find KDC for realm LOCALHOST.LOCALDOMAIN", which sends an operator hunting for a KDC.
4. **A9 — "domain users' homes go outside the boot environment" — is not achieved.**
   `/var/lib/os7/domain-homes` resolves to `rpool/ROOT/<be>`. `New-OS7Storage` creates no
   dataset for it and `$script:OS7DomainHomeRoot` is the only place the path is named. The
   sssd document is right and the layout it depends on does not exist, so `Restore-OS7` rolls
   domain homes back with the operating system today. The fix is a storage-layout decision
   (D10 / SETUP-PLAN) plus a migration, the same two halves BUILD-NOTES #74 needed. **Open, and
   not decided here.**

## A finding about leaving, not joining

After `Remove-OS7Domain`, with `sssd.conf` and the keytab deleted, `sssd.service` inactive and
**no sssd process running**, this still answers:

```
getent passwd t.user1        -> t.user1:*:1856801103:...
getent passwd 1856801103     -> t.user1:*:1856801103:...
```

sssd's responders are socket-activated, so a lookup starts one on demand and it answers from
`cache_os7test.local.ldb`, which `Remove-OS7Domain` left in place. A machine that had left the
domain therefore still resolved domain identities in both directions, which is how a file owned
by a departed account keeps showing that account's name.

**Fixed the same day.** `Remove-DirectoryRealm` now asks `sss_cache -E` **before** it deletes
`sssd.conf` — the order is load-bearing, because sss_cache reads that file to learn which
domains exist — and then removes **that domain's** cache databases by name
(`cache_<domain>.ldb`, `timestamps_<domain>.ldb`, `ccache_<REALM>`). Only that domain's: a host
can have more than one configured, and wiping the directory would take another realm's
identities with it. Every path deleted is reported in the returned object, so "left the domain"
is checkable rather than a sentence. Invalidation is best-effort and its absence is reported
(`CacheDetail`) rather than passed off as success.

Re-measured on the `domain-joined` snapshot, which is the machine that produced the finding:

| | before the fix | after |
|---|---|---|
| `getent passwd t.user1` | resolved | empty |
| `getent passwd 1856801103` | resolved | empty |
| `id -nu 1856801103` | `t.user1` | `no such user` |
| `/var/lib/sss/db` | four files | `config.ldb` only |

That run also shows the reporting working in the operator's favour by accident: the bench's
DNS pointing is set at runtime and does not survive a snapshot restore, so `adcli` could not
reach the domain controller and `ComputerAccountRemoved` came back **False** with the reason.
The local state was still cleaned — which is right, a machine must be able to leave a domain it
cannot reach — and the account was left in the directory for an operator to remove, said out
loud instead of silently.

## What this does not say

- **Screen 9D has still never drawn.** The installer's road to the join is unexercised, and it
  cannot pass `-UseLdapPassword`.
- **The join was driven by hand, not by a harness.** `check-ad.py` performs no join, and this
  session's scripts live in a scratchpad. Tier 3 of A11 is now "run", not "checked".
- **Not measured:** `Repair-OS7Domain` (the `adcli update` path), the one-time-password road a
  fleet should take, GPO-derived logon rights, offline/cached-credential login, and an actual
  interactive password login through PAM — `sssctl user-checks` exercised the account phase,
  and Kerberos proved the password, but no console or ssh session was opened as a domain user.
- **arm64 remains entirely unmeasured** (AL7).
- The machine reached the DC through QEMU user-mode NAT inside Docker inside WSL2. That the NAT
  case is now supported is a product improvement; that this bench exercises it is an accident of
  the harness, not a deliberate coverage choice.
