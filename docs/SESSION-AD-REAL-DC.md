# Session: the AD surface against a real Windows Server domain controller

**Dates:** 2026-09-05 / 2026-09-06 · **Host:** x64 Windows 11 + Hyper-V (UIB-BW-PC) · **OS/7 side:** amd64, os7lab bench `gui`, image 1.0.0.163 modules

Until this session every AD measurement in this repository was taken against **Samba** in a
container (`check-ad.py`, AD-PLAN §"Proven"). AD-PLAN **AL3** says in as many words what that
does not cover: *"Windows password-policy plumbing and its error sub-codes"*. This session put a
real Windows Server 2025 domain controller next to the OS/7 machine and drove the whole
`Directory`/`OS7.Directory*` surface against it. The read surface and the write surface are
correct. AL3 was right about where the one gap is.

## What was built (not in this repository)

A Hyper-V VM `OS7-DC01`, Windows Server 2025 **Standard Core**, forest `os7test.local`
(NetBIOS `OS7TEST`), static 192.168.178.41/24 on an external switch, DNS on itself, WinRM on.
OU `OS7Test`, group `OS7-Testers`, users `t.admin` (Domain Admins), `t.user1`, `t.user2`,
`t.disabled` (ACCOUNTDISABLE), `t.mustchange` (pwdLastSet 0). Fully unattended: `autounattend.xml`
on a second DVD, a staged provisioning script that survives the dcpromo reboot through an
AtStartup scheduled task, PowerShell Direct as the only monitoring channel. The build scripts live
in the session scratchpad (`os7dc/Setup-OS7DC.ps1`, `Provision-DC.template.ps1`), the summary with
addresses and credentials in `os7dc/dc-summary.json`. They are lab tooling, not product, and are
deliberately not committed.

**A fresh DC has no LDAPS.** Port 636 accepts the TCP connection and closes the TLS handshake
having sent 0 bytes (`openssl s_client`), because nothing in the machine store has a Server
Authentication certificate. A lab root CA (`CN=OS7 Lab Root CA`) and a server certificate with
SAN `os7-dc01.os7test.local` were created on the DC, `renewServerCertificate` told AD DS to
load it, and 636 then presents it over TLS 1.3. The root CA PEM is what `Add-OS7DirectoryTrust`
was given on the OS/7 side.

## What was measured, OS/7 side

Bench `gui` restored to `installed`, CA pushed to `/tmp`, hosts entry for the DC (QEMU's
10.0.2.3 resolver knows nothing about `os7test.local`). Scripts and full output:
`os7dc/os7-side-test.ps1`, `os7-side-write-test.ps1`, `os7-side-write-test2.ps1` and their
`.out` files in the scratchpad. The end state is snapshot **`ad-trusted`** on bench `gui`.

| step | result |
|---|---|
| `Test-OS7Directory -Server` **before** trust | `Reachable=False, CertificateTrusted=False`, Detail names the missing CA and `Add-OS7DirectoryTrust`. The OpenLDAP "server unavailable" ambiguity is separated as designed |
| `Add-OS7DirectoryTrust` | `Installed=True`, fingerprint read back from the store |
| `Test-OS7Directory -Server` **after** trust | `Ready=True, Encrypted=True, CertificateTrusted=True`, clock skew 3.4 s, `Identity=u:OS7TEST\t.admin` |
| `Test-OS7Directory` without `-Server`, QEMU resolver | `Ready=False`, "DNS published no domain controller" — the resolver answered REFUSED, and that is what the object says |
| `Enter-OS7AdminSession` | port 636, Basic over TLS, WhoAmI `u:OS7TEST\t.admin`, `DefaultNamingContext=DC=os7test,DC=local` |
| `Get-OS7ADDomain` | DFL/FFL 10, DC `OS7-DC01.os7test.local`, SASL `GSSAPI, GSS-SPNEGO, EXTERNAL, DIGEST-MD5` |
| `Get-OS7ADUser -Filter`, `-Identity` | five users, `Enabled` correct for `t.disabled`, `AccountControl` decoded (`ACCOUNTDISABLE, NORMAL_ACCOUNT, DONT_EXPIRE_PASSWORD`), SID/GUID/MemberOf present |
| `Get-OS7ADGroup`, `Get-OS7ADGroupMember`, `-Recursive 'Domain Admins'` | 5 members typed as users; recursive returns `Administrator` and `t.admin` |
| `Get-OS7ADOrganizationalUnit`, `Get-OS7ADComputer` | both OUs; the DC as computer with OS `Windows Server 2025 Standard 10.0 (26100)` |
| sign in as `t.disabled` | refused, **"the account is disabled (LDAP 49, data 533)"** |
| sign in as `t.mustchange` | refused, **"the password must be changed before the account can be used (LDAP 49, data 773)"** |
| sign in as `t.user1` (no admin rights) | signed in as `u:OS7TEST\t.user1` — the session is the account's, as AD-PLAN wants |
| resolver pointed at the DC, `Get-OS7ADDomainController` | found by SRV: `os7-dc01.os7test.local:389`, prio 0, weight 100; `Test-OS7Directory` without `-Server` then `Ready=True` |
| `New-OS7ADUser -Enabled -Password` | create-disabled → password → enable, read back `Enabled=True`, the account signs in itself |
| `Set-OS7ADUser -Department -Title` | read back |
| `Add-/Remove-OS7ADGroupMember` | membership read back after each |
| `Reset-OS7ADAccountPassword -MustChangeAtNextLogon` | the account is then refused with **data 773** |
| `Remove-OS7ADObject` | read back: 0 objects |

Everything AL3 listed under channel binding and signing behaves as AD-PLAN measured: an
unsigned simple bind on 389 is refused with *"Strong authentication is required"* — on this DC
with `LDAPServerIntegrity=1`, i.e. the default, not the hardened value.

## The finding: 0x52D reaches the operator untranslated

`New-OS7ADUser` with a `-DisplayName` of `OS7 Created` and a password that contained the token
`OS7` failed at the password step, and so did `Enable-OS7ADAccount` on that account and
`Reset-OS7ADAccountPassword`, all with:

```
Exception calling "SendRequest" with "1" argument(s): "The server cannot handle directory
requests. 0000052D: SvcErr: DSID-031A12C5, problem 5003 (WILL_NOT_PERFORM), data 0
```

**The cause is the domain's complexity rule, not the unicodePwd path.** Windows rejects a
password that contains any token of three or more characters from the account's `displayName`.
The users created on 2026-09-05 carried no `displayName` (`New-ADUser -Name` sets `cn`, not
`displayName`), so the rule never fired for them. (Live lab passwords are kept out of this
public repo; the two columns below describe the password, they do not quote it.) Confirmed
from both sides:

| account | password | OS/7 `New-OS7ADUser` | DC, `Set-ADAccountPassword` |
|---|---|---|---|
| displayName `OS7 Created` | contains the token `OS7` | 0x52D | *"does not meet the length, complexity, or history requirement"* |
| displayName `Lab Test` | contains the token `Test` | 0x52D | — |
| no displayName | same password, no name to clash with | accepted, signs in | accepted |
| displayName `OS7 Created` | no token of the display name | accepted, signs in | accepted |

What this says about OS/7:

1. **`Set-DirectoryPassword` is correct**: UTF-16LE, quoted, Replace, refused first over a
   channel that is not TLS. Nothing to change there.
2. **The failure is not translated.** `Get-DirectoryErrorMeaning` already has a sentence for
   LDAP 53 (*"an unencrypted channel, or a policy violation"*) but the password path raises the
   raw `SendRequest` exception, so the operator reads *"the server cannot handle directory
   requests"* — a sentence about the server, for a problem with the password. That is exactly
   the shape AL3 predicted, and the same shape as the 49/data-773 sub-codes this module already
   decodes for binds. A `0000052D` in the server message deserves its own meaning ("the domain's
   password policy refused this password"), and `New-OS7ADUser` should say which of its three
   steps failed — the account exists, disabled, after this error, and the read-back at the end
   of `New-OS7ADUser` never runs because the exception leaves the function first.
3. **Samba would not have shown this.** Samba's complexity check does not consult
   `displayName` tokens the same way, and `check-ad.py`'s fixtures set no `displayName`. This
   is the argument for a `check-ad.py` stage against Windows, or for keeping this DC.

**Fixed 2026-09-07** (commit "A directory operation refusal (0x52D) becomes a sentence"):
`Get-DirectoryErrorMeaning` reads the operation sub-code as well as the bind one;
`Invoke-DirectoryRequest` — the single chokepoint every write and search passes through —
translates any failure it can name and re-throws unchanged the ones it cannot; and
`New-OS7ADUser` winds the disabled stub back rather than leaving it. Re-measured against this
DC afterwards: the message is now *"the domain's password policy refused this password (its
length, complexity, or history) (LDAP 53, code 0000052d)"*, no stub is left behind, and a
policy-clean password still creates an account that signs in.

## Eight cmdlets added, 2026-09-07, and measured here

The surface had gaps that this session's own testing walked into — the OU the test users live
in had to be created with Windows tooling, because OS/7 could read OUs and not make one.
Added and driven against this DC (`os7dc/os7-side-new-cmdlets.ps1`, output beside it):

| cmdlet | what it settles | measured here |
|---|---|---|
| `New-/Set-/Remove-OS7ADOrganizationalUnit` | an OU's RDN is `OU=`, not `CN=`; a populated OU is refused with the child count rather than LDAP 66 | nested OU created, described, non-empty delete refused, child then parent deleted |
| `Get-OS7ADPrincipalGroupMembership` | the inverse membership question, and the **primary group AD keeps out of `memberOf`** | `t.admin` → Domain Admins + OS7-Testers + **Domain Users**; `-Recursive` adds Administrators and the RODC group; the DC's computer object → Domain Controllers |
| `Set-OS7ADGroup`, `Remove-OS7ADUser`, `Remove-OS7ADGroup` | `Set-`/`Remove-` by identity, which only users and DNs had | set and cleared description/mail/displayName; both deletes by `sAMAccountName`; an unmatched name refuses without deleting |
| `Set-OS7ADAccountExpiration` | `accountExpires` was readable and not writable | `2026-12-31 18:00Z` → FILETIME 134432136000000000, read back to the same instant; `-Never` → raw `0`, read back `$null` |

Two decisions are recorded as deliberately absent rather than half-built: an OU created here is
**not** protected from accidental deletion (that is a DENY ACE on `nTSecurityDescriptor`, and
this surface writes no ACLs anywhere yet, so a Windows admin's expectation is documented instead
of faked), and `Remove-OS7ADOrganizationalUnit` has **no `-Recursive`** (Windows uses the
tree-delete control, which the Directory layer does not send; a one-word switch that removes a
hundred accounts is not a surface to hand out).

**A second defect, found by running it:** `Get-OS7ADPrincipalGroupMembership` threw *"The
property 'MemberOf' cannot be found on this object"* for a **computer** — `memberOf` is not in
`$script:OS7AdComputerAttributes`, so `OS7.AD.Computer` has no such property, and the cmdlet had
reached into the shape a converter produced. It now asks the directory for `memberOf`,
`primaryGroupID` and `objectSid` in one read and assumes nothing about the object's shape.
`check-directory-logic.py` gained a computer fixture deliberately lacking `memberOf` to hold it,
along with twelve other cases for the new cmdlets (28 in total, all green, no DC required).

## What this does not say

- **The join (Stage 2) was not run.** `Join-OS7Domain` and screen 9D remain unmeasured; AL1 stands.
- **Kerberos was not exercised.** No ticket, no `-UseKerberos`; the DC's 88/tcp merely answers.
- **arm64 is unmeasured**, as everywhere in the AD surface.
- The OS/7 machine reached the DC through QEMU user-mode NAT out of a Docker container out of
  WSL2. That it could is a fact about this host's network, not about the product.
- `Test-OS7Directory`'s clock reading (3.4 s, then 2.7 s) is between two VMs on the same box.

## Traps paid for while building the DC (Hyper-V, not OS/7)

- **A Generation 2 VM is created with NO DVD drive.** `Set-VMDvdDrive -Path` on it is a silent
  no-op, and the subsequent `Add-VMDvdDrive` for the answer file became the only drive, so the
  firmware had nothing bootable. `Add-VMDvdDrive` both, with explicit controller locations, and
  count them back.
- **`FirstLogonCommands/CommandLine` is capped at 1024 characters.** An 11.5 KB base64-inlined
  script failed the oobeSystem pass with *"Value is invalid"*, and Setup showed only *"Windows
  could not complete the installation"*. The answer was in `C:\Windows\Panther\UnattendGC\setuperr.log`,
  read by mounting the VHDX. Ship scripts as files on the answer-file ISO.
- **After dcpromo, PowerShell Direct wants `OS7TEST\Administrator`.** The bare local name
  authenticated for 22 minutes and then never again; the poller reported a 90-minute TIMEOUT
  for a machine that had been READY since minute 22. A diagnostic that stops working at the
  moment of success — BUILD-NOTES' recurring shape, in a new place.
- **A UAC prompt cancels itself after about two minutes**, and "canceled by the user" is also
  what an RDP session with nobody at it produces. One elevation running a job loop replaced one
  elevation per command.
- **Automatic checkpoints** wrap the disk in an `.avhdx` at every start; off for a DC.

## What changes in the plan

- AD-PLAN's "Proven" table can gain a row: the admin session and the object surface are proven
  against **Windows Server 2025**, on a machine, both directions — everything except the join.
- AL3 shrinks to: password-policy sub-code *translation* (measured, above), `msDS-*`
  constructed attributes, Windows LAPS, cross-forest referrals — the last three still unmeasured.
- A real DC is now a fixture this host has. Whether `check-ad.py` grows a stage against it, or
  the DC is rebuilt on demand from the scratchpad scripts, is open.
