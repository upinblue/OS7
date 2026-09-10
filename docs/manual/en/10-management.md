# 10 The management plane: Entra ID, Intune and Azure Arc

OS/7 is managed through Microsoft's own tooling. Three of those, and they are
**three separate things** with three separate answers:

![The three management paths and the one command that asks all three.](images/diagram-management-en.svg)

## 10.1 All three at once

```powershell
Get-OS7ManagementStatus | Format-List
```

![The three paths in one answer, with a summary that names the first cause.](images/81-management.png)

This is the command for the overview. `Summary` does not merely say that
something is missing but **why** — which in this corner is the more important
half of the answer.

`-SkipNetwork` omits the endpoint reachability check; the command then answers
immediately and purely from what is on the machine.

## 10.2 Entra ID — can anyone sign in here

```powershell
Get-OS7EntraStatus | Format-List
```

![Whether a user can sign in with an Entra account — and if not, which link of the chain is missing.](images/82-entra.png)

Signing in with an Entra account on Ubuntu goes through **authd**, a broker
that connects PAM to OpenID Connect. Three things have to hold:

1. `authd` is installed;
2. PAM is wired to `authd`;
3. there is a **broker** — the piece that actually talks to Entra.

The third is the one that is missing in practice, and its absence looks like
something else entirely: a sign-in attempt then fails **as though the password
were wrong**. That is exactly why `Get-OS7EntraStatus` is the first thing to
ask on a machine nobody can sign in to — it names the missing link instead of
confirming a guess.

## 10.3 Intune — is the device enrolled

```powershell
Get-OS7IntuneEnrollment | Format-List
```

![What can be said about Intune on this machine — and what cannot.](images/83-intune.png)

The command reads what the Intune portal has left on the machine: whether it is
installed, whether an enrolment exists, when the device last checked in.

It also says explicitly what it **cannot** answer. A device's compliance state
is evaluated in the tenant, not on the device; a machine claiming to be
compliant would not know. Where the answer lives only in the tenant, that is
said rather than guessed.

Intune enrolment and the portal exist on **amd64**; Microsoft does not ship
them for arm64.

## 10.4 Azure Arc — is the machine inventoried

```powershell
Get-OS7ArcStatus | Format-List
```

![Whether the Azure Connected Machine agent is installed, and what it says about itself.](images/84-arc.png)

Arc brings a machine into Azure as a resource without it running in Azure — for
inventory, policy and update management. `Get-OS7ArcStatus` asks the `azcmagent`
agent itself rather than concluding from the existence of a file that it is
connected.

> The agent's state lives **outside** the boot environment. A rollback
> therefore does not take an Arc onboarding back with it — and that is
> intended, because Azure does not roll back either.

## 10.5 When management does not take

The order to ask in, because each stage is a prerequisite for the next:

```powershell
Get-OS7TimeSynchronization      # 1. is the clock right?
Test-OS7Network                 # 2. does the machine get out at all?
Test-OS7Network -Endpoint Entra, Intune, Arc   # 3. does it reach the right endpoints?
Get-OS7ManagementStatus         # 4. and what do the three paths say themselves?
```

The clock is deliberately first. A wrong clock brings down every token-based
sign-in, and the error it produces points in a completely different direction.

## 10.6 What is deliberately absent

**Group Policy.** There is no GPO engine for Linux. A domain-joined machine can
**enforce** logon-right policy — that is consumption, not administration.

**Anything over RPC or DCOM.** `repadmin`, `dcdiag`, `netdom`, DNS and DHCP
server management, certificate enrolment: no cross-platform client exists.
