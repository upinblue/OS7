# 11 Active Directory

There are **two entirely different things** you can do with Active Directory,
and they are regularly confused. OS/7 keeps them strictly apart:

![Administering and becoming a member are independent of each other.](images/diagram-active-directory-en.svg)

**Administering** means: an administrator signs in to the directory **from** an
OS/7 machine with their own AD account and works as themselves — creates users,
maintains groups, resets passwords. For that the machine is **not a domain
member**, needs no computer account and no extra package. It is an outbound
LDAPS connection and nothing else.

**Becoming a member** means: the machine itself gets a computer account in the
domain, so that domain users can sign in **to it**.

If all you want is to maintain directory objects, you do not need the second.

## 11.1 Preparation: the domain controller's certificate

The connection is **LDAPS on port 636**, and that is not a default but the only
route: Active Directory refuses a simple bind on port 389, and the
sign-and-seal a Windows client would use instead does not exist on Linux.

For the machine to accept the domain controller's certificate, the issuing
authority has to be known:

```powershell
Add-OS7DirectoryTrust -Path /path/to/contoso-ca.crt -Name contoso-issuing-ca
```

The command installs the certificate machine-wide and then **reads back** that
it took.

Whether the prerequisites hold:

```powershell
Test-OS7Directory -Domain contoso.local
```

The command walks the chain — DNS, reachability, TLS, bind — and says which
link is missing. It also measures the **clock skew against the domain
controller's own clock**; see chapter 8.

## 11.2 Signing in

```powershell
Enter-OS7AdminSession -Domain contoso.local
```

The command asks for credentials and opens a session **for this shell**.
`-Credential` passes them ready-made, `-Server` names a particular domain
controller instead of the one found through DNS.

```powershell
Get-OS7AdminSession
```

Note what is reported: **the identity the server hands back** — not the name
you signed in with. A bind that raised no exception is not proof of who you
are; a silent fall back to an anonymous bind would otherwise look like a
success.

Closing the session:

```powershell
Exit-OS7AdminSession
```

> **The credential is used and then forgotten.** There is no session that can
> re-authenticate itself later — that would be a password at rest. After the
> shell restarts you sign in again.

## 11.3 Users

```powershell
Get-OS7ADUser -Identity jsmith
Get-OS7ADUser -Filter '(department=Sales)' -SearchBase 'OU=London,DC=contoso,DC=local'
Get-OS7ADUser -Identity jsmith -Property department, manager, lastLogonTimestamp
```

`Enabled` and `LockedOut` are **separate answers from separate places**. A
locked account is not a disabled one, and confusing them leads to remedies that
change nothing.

Creating an account:

```powershell
$pw = Read-Host -AsSecureString -Prompt 'Password'
New-OS7ADUser -Name jsmith `
    -Path 'OU=London,DC=contoso,DC=local' `
    -DisplayName 'Jane Smith' `
    -GivenName Jane -Surname Smith `
    -UserPrincipalName jsmith@contoso.local `
    -Mail jsmith@contoso.local `
    -Password $pw -Enabled
```

The order behind that is forced rather than chosen: Active Directory creates an
account **disabled**, then takes the password, and only then lets it be
enabled. An account asked for with a password and enabled in one go is
rejected.

Changing, disabling, unlocking:

```powershell
Set-OS7ADUser -Identity jsmith -Department Sales
Disable-OS7ADAccount -Identity jsmith
Enable-OS7ADAccount  -Identity jsmith
Unlock-OS7ADAccount  -Identity jsmith
```

`Enable-` and `Disable-` read the existing flags and change **one bit**. They
do not rewrite the whole value, so nothing else is discarded along the way.

Resetting a password:

```powershell
$pw = Read-Host -AsSecureString -Prompt 'New password'
Reset-OS7ADAccountPassword -Identity jsmith -NewPassword $pw -MustChangeAtNextLogon
```

Over an unencrypted connection the command refuses **before** the password
reaches the wire.

## 11.4 Groups

```powershell
Get-OS7ADGroup -Identity 'Sales-London'
Get-OS7ADGroupMember -Identity 'Sales-London'
Get-OS7ADGroupMember -Identity 'Sales-London' -Recursive

New-OS7ADGroup -Name 'Sales-London' -Path 'OU=Groups,DC=contoso,DC=local' -Scope Global

Add-OS7ADGroupMember    -Identity 'Sales-London' -Member jsmith, rjones
Remove-OS7ADGroupMember -Identity 'Sales-London' -Member rjones
```

`-Recursive` uses the directory's own matching rule rather than rebuilding the
nesting in the client. And `Add-OS7ADGroupMember` adds — it does not replace
the membership list.

## 11.5 Computers and organisational units

```powershell
Get-OS7ADComputer -Identity WS-LON-014
Get-OS7ADComputer -Filter '(operatingSystem=*Server*)'
Get-OS7ADOrganizationalUnit -SearchBase 'DC=contoso,DC=local'
Move-OS7ADObject -DistinguishedName 'CN=WS-LON-014,CN=Computers,DC=contoso,DC=local' `
                 -TargetPath 'OU=London,DC=contoso,DC=local'
Rename-OS7ADObject -DistinguishedName 'CN=old,OU=…' -NewName new
```

Nobody has to type a computer account's trailing `$`.

## 11.6 When the curated surface is not enough

A directory surface you cannot escape from would have to be complete. So the
raw access sits beside it:

```powershell
Search-OS7AD -Filter '(&(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' `
             -SearchBase 'DC=contoso,DC=local' -Scope Subtree

Get-OS7ADObject -DistinguishedName 'CN=Jane Smith,OU=London,DC=contoso,DC=local'
Set-OS7ADObject -DistinguishedName 'CN=Jane Smith,OU=…' -Name extensionAttribute1 -Value 'X'
Remove-OS7ADObject -DistinguishedName 'CN=old,OU=…'
```

Searches follow the pages to the end — a result is never silently cut off at
1000 objects.

## 11.7 Joining a domain

So that **domain users can sign in to this machine**, it joins the domain:

```powershell
$pw = Read-Host -AsSecureString -Prompt 'Password of the join account'
Join-OS7Domain -Domain contoso.local `
    -UserName joiner `
    -Password $pw `
    -OrganizationalUnit 'OU=Linux,OU=Servers,DC=contoso,DC=local' `
    -AllowGroup 'CONTOSO\Linux-Users' `
    -AdministratorGroup 'CONTOSO\Linux-Admins'
```

`-AllowGroup` decides who may sign in; `-AdministratorGroup` who may administer
the machine. The `sudo` rule that results is checked by `visudo` before it
counts — a malformed rule would otherwise break every elevation on the machine.

The password goes to the join tool on **stdin**, never as an argument; an
argument would sit in the process list.

State and verification:

```powershell
Get-OS7Domain | Format-List
Test-OS7Domain -Domain contoso.local
```

![Whether this machine is a member of a domain — as configured and as it actually stands.](images/a0-domain.png)

`Get-OS7Domain` again answers both halves: what is configured, and what
actually holds. `Test-OS7Domain` checks whether the membership **works** —
whether a directory account resolves through the system's name service. That is
the only question whose answer proves a working join.

Changing the logon policy afterwards:

```powershell
Get-OS7DomainLogonPolicy
Set-OS7DomainLogonPolicy -AdministratorGroup 'CONTOSO\Linux-Admins'
```

After a **rollback** the machine account can be stale, because the domain has
changed the password since and the boot environment brought the old state back:

```powershell
Repair-OS7Domain -Domain contoso.local
```

Leaving:

```powershell
Remove-OS7Domain -Domain contoso.local -UserName joiner -Password $pw
```

## 11.8 Kerberos tickets

```powershell
Get-OS7KerberosTicket
New-OS7KerberosTicket -Principal administrator@CONTOSO.LOCAL
Remove-OS7KerberosTicket
```

![This session's Kerberos tickets.](images/a2-kerberos.png)

The realm is upper-case — that is Kerberos convention, not a choice.

> **Domain users' home directories live outside the boot environment**, exactly
> like the local ones. Otherwise a rollback would take signed-in domain users'
> files back with it.
