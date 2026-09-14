# The identity and access management application

**Status: every decision here is *Proposed*, written 2026-09-14. Nothing is built.**

A generic, connector-based provisioning and governance engine for identities and
entitlements, with one permission-scoped web application over it, delivered as an OS/7
appliance.

**It is not an operating system feature and must not become one.**
[AUTOMATION-PLAN.md](AUTOMATION-PLAN.md) AU1 draws that line from the other side: the machine
provides primitives, an application above provides policy. Roles, separation of duties,
attestation campaigns and an employee lifecycle have nothing to do with administering a
machine, and routing them through the cmdlet surface would end with two hundred cmdlets of
business logic in `powershell/OS7/` and an OS module that is an identity product wearing a
PowerShell skin.

The capability scope — what is built, what is deliberately not, and the technical reason for
each — is [IAM-SCOPE.md](IAM-SCOPE.md).

---

## 1. What was measured, and what was not

**Measured**, and every one of these is already recorded elsewhere in this repository because
the directory work paid for it ([AD-PLAN.md](AD-PLAN.md)):

- `System.DirectoryServices.Protocols` ships **inside** pwsh 7.6.5 on Linux, resolves with no
  `Add-Type` and reaches `libldap`. `System.DirectoryServices` (ADSI) loads on the same host
  and *then* throws "not supported on this platform" — one is a foundation, the other a trap,
  and only asking separates them.
- `AuthType.Negotiate` with an explicitly supplied credential returns **LDAP rc 92**;
  `SessionOptions.Sealing` throws on Linux; Active Directory refuses a simple bind on port
  389. Therefore a simple bind over LDAPS on 636, and there is no third option.
- Behind NAT, adcli's Kerberos set-password path fails with "Message stream modified" and an
  LDAP modify of `unicodePwd` works.
- AD's `MaxPageSize` is 1000, and the failure mode of ignoring it is a short list and **no
  error at all**.
- A bind that raised no exception is not proof of identity; RFC 4532 (`whoami`) is, and it is
  what catches a fall back to anonymous.

**Not measured.** Everything else, including every claim about Microsoft Graph, Exchange
Online, SQL Server client behaviour on Linux and SPNEGO in ASP.NET Core. §7 lists what each
costs to find out.

---

## 2. The genericity rule

Two tests. A feature that fails either is not built. They exist because the failure they
prevent is invisible for about a year and then permanent.

**Test 1 — the convention test.** Every deployment-specific convention becomes configuration,
or it is not built. A group-nesting model such as AGDLP is not a function; it is a shipped
template of a naming-and-placement policy. An employee state such as "parental leave" is not
a state in the code; it is a row in a state machine made of data.

**Test 2 — the new-source test.** Could a source system nobody has heard of be added without
touching the core? If `if (system == "AD")` appears anywhere in the core, what exists is a
single-deployment project with configuration files on top.

---

## 3. Decisions

### IG1 — One application, one permission model, one deployment. Proposed 2026-09-14.

Administrative use and self-service are **one web application**, separated by permission
alone — because two front-ends means two permission models and the second is always the
weaker one. Plus exactly one separable door: password reset, which has its own security
posture (an unauthenticated front door, identity proofing) and is deployable on a different
host.

**Consequence: there is no desktop client, so this application does not touch G1.** The
Avalonia decision stays what it was made for — administering *the machine*
([GUI-APPS-PLAN.md](GUI-APPS-PLAN.md)). Nothing here competes with it and nothing here
depends on it.

### IG2 — No target system exists in the core. Proposed 2026-09-14.

Active Directory is a connector like any other. Entra is a connector. A personnel system is a
connector that happens to be read-only and authoritative. The core knows *object types,
operations, attributes and capabilities* — never a product name.

This is Test 2 made structural.

### IG3 — The object model is thin and fixed; everything variable is schema. Proposed 2026-09-14.

`Identity, Account, Entitlement, Assignment, Resource`. Five. Everything a given deployment
cares about — cost centre, works-council flag, badge number, whether a person is internal or
external — is an attribute against a schema defined per installation, never a class.

A model that grows a class per requirement is the failure this decision prevents, and it
cannot be undone once data is in it.

### IG4 — Rules are data, evaluated, never compiled. Proposed 2026-09-14.

A rule is a condition over identity attributes producing a set of entitlements, expressed in
a small total expression language with no I/O and no arbitrary code, evaluated by the engine.

The reason is not elegance. A rule that is code cannot be shown to an auditor, cannot be
diffed, cannot be validated before it runs, and cannot be authored by anyone but a
programmer — which loses every "without programming" requirement in one move.

### IG5 — Every derived fact carries its derivation. Proposed 2026-09-14.

Why does this identity hold this entitlement? *Rule 14, via department = Sales* — or
*request 8812, approved by Meier on 3 March*. Not a flag; the actual path.

**This is a core condition, not a feature.** Without it, three things are not merely missing
but unimplementable, and unimplementable *late*, after the model is fixed: reporting
individual assignments against role-derived ones, showing the permission path of every
authorised principal, and attestation of any kind. It is the same discipline as BUILD-NOTES
#64 — say why, or the answer is not an answer.

### IG6 — The plan is an artifact. Proposed 2026-09-14.

A plan is produced, inspected, validated, approved, stored, and applied — possibly days
later, possibly by someone else. It is not a preview and not a log line.

Everything difficult then becomes a **producer or a validator of plans** rather than a new
engine: the reconciler produces one by diffing desired state against observed, an attestation
campaign produces one that asks a human about the existing state instead of changing it,
separation-of-duties validates one before it is applied, and an approval is a plan that
waits.

OS/7 already has this shape twice — `Update-OS7` is plan, driver gate, apply, read back; and
every changing cmdlet carries `SupportsShouldProcess`. This decision is `-WhatIf` promoted
from a switch to an object.

### IG7 — The core plans only what a connector declares it can do. Proposed 2026-09-14.

Every connector ships a capability manifest: object types, operations per type, attributes
and their types, whether it can report changes since a watermark, what it is authoritative
for, its rate limits, whether an operation is atomic.

Two things then fall out instead of being built. **The attribute mapping surface** is
generated from two manifests rather than written per system. And **a plan a connector cannot
execute is refused at design time**, rather than discovered at 03:00 against production.

### IG8 — Multiple directories are N connector instances, never a special case. Proposed 2026-09-14.

Single domain, multiple domains in one forest, and domains across forests are the same
mechanism with a different count. A model in which "the domain" is a property of the
installation cannot grow a second one; a model in which a *system instance* is a configured
connector gets all three, and gets a test directory beside production for free.

### IG9 — There is no per-deployment code. Five extension points, named. Proposed 2026-09-14.

Connector configuration, attribute mapping, rules, workflow definitions, and PowerShell
script steps. Nothing else.

**If a deployment needs a change to the product's code, the product is not yet generic.**
That is not a process rule; it is §2 being enforced.

### IG10 — A change is verified by reading it back, never by an exit code. Proposed 2026-09-14.

Provisioning engines drift because they write, receive a success, and treat their own cache
as the truth — which is why products in this category grow a periodic full reconciliation to
repair a database that should not have been wrong.

This application asks the target. The cache is explicitly a cache, carries an age, and **a
value that was not looked up reads as "not looked up" and never as "unchanged"**. That is
OS/7's `$null`-is-never-`$true` rule, which is P5 and P6 wearing different clothes.

### IG11 — Script steps run out of process, on the OS's job contract. Proposed 2026-09-14.

Operator-authored PowerShell runs as `pwsh -NoProfile -NonInteractive` under
[AUTOMATION-PLAN.md](AUTOMATION-PLAN.md) AU3/AU4 — input on stdin, limits, timeout,
isolation — and **not** by hosting `System.Management.Automation` inside the web or worker
process. A hosted runspace means module state leaking between runs, no timeout that actually
kills, and one script that takes the process down with it.

Those scripts run in a `pwsh` where OS/7's own modules are present, so a step may call
`Get-OS7ADUser`. **The cmdlet surface is the extension API for operator scripts; it is not
the application's own plumbing** — see §4.

### IG12 — A runbook is a document; a step may be a script. Proposed 2026-09-14.

Pure script: full power, zero analysability — no plan before execution, no validation, no
diff. Pure document: analysable, and it makes IG11 impossible.

So the document is the plannable skeleton — which steps, against which connector, with which
inputs, which gates — and a step's body may be arbitrary PowerShell. The engine plans at step
level and **says when it cannot see inside**: a script step appears in the plan as *opaque*,
with the target it will run against and the identity it will run as.

A step that was not analysed must not look like one that was checked. Same rule as IG10.

### IG13 — After a crash, a step is re-planned, not re-run. Proposed 2026-09-14.

A running PowerShell pipeline cannot be frozen, so the unit of resumption is the step, and
the journal writes intent before action (AU5). The hard case is a crash mid-step, where the
engine cannot know whether the write landed.

The answer is not retry. It is: read the target's current state, diff again, and let the
idempotent operation become a no-op if it already happened. **This is why IG10 is not a
stylistic preference — "ask the thing itself" is the only basis on which crash recovery can
be correct.** An engine that trusts exit codes can only guess.

### IG14 — An automated agent may be a requester. It may never be an approver. Proposed 2026-09-14.

Three levels, to be shipped in this order:

1. **Read.** Natural language over observed state — "who can reach this resource, and by what
   path" is a graph query over IG5's derivations. No trust problem.
2. **Author artifacts.** Rules, mappings, workflows and connector configurations produced as
   reviewable, diffable artifacts that pass through the same validation as human-authored
   ones. IG4 and IG9 are what make this possible; a product whose rules are code cannot do
   it at all.
3. **Act** — only by producing a plan that the engine validates and a human approves.

The product already requires a four-eyes principle for exception approval and already records
every requester and approver with a timestamp. An agent therefore needs an identity in that
record, and "on whose behalf" beside it. **IG6 is what makes any of this reviewable**, which
is why this costs nothing extra if the plan is a real artifact and is impossible if it is
not.

---

## 4. Architecture, and what OS/7 contributes

Three tiers, and the split is forced by where credentials may live:

- **Web tier** — Kerberos/SPNEGO for desktop single sign-on (M-IG4), OIDC against Entra for
  the second factor where policy requires one. **Holds no target-system credential.**
- **Worker tier** — reconciler, planner, executor, connectors. The only tier that reads
  `$CREDENTIALS_DIRECTORY` (AU2). Owns the heartbeat and the due-work store (AU12).
- **Database** — see open question 2.
- **The separable door** — password reset, its own deployment, later.

What it uses from the machine is exactly [AUTOMATION-PLAN.md](AUTOMATION-PLAN.md) §4 and
nothing else.

**What OS/7 contributes as code:** the appliance itself — ZFS root, encrypted, TPM unlock,
Secure Boot, the installer — rollback-safe updates with the evidence deliberately outside the
rollback (D10), snapshots, signed delivery of the application and its connectors with the
update train (AU9), and PowerShell as the extension host (IG11).

**What it contributes as measured knowledge:** §1. Every line of it is a week not lost.

**What it does not contribute: the AD cmdlets.** A .NET application has
`System.DirectoryServices.Protocols` natively, and starting a `pwsh` per LDAP operation would
be slow and pointless. The application writes its own directory layer with §1 as the
blueprint. **The consequence for OS/7's own roadmap is that its AD surface should stop
growing toward being a provisioning engine** — its purpose stays [AD-PLAN.md](AD-PLAN.md)'s:
an administrator managing AD *from* an OS/7 machine, as themselves.

---

## 5. Limitations — the honest list

- **IGL1 — Nothing is built and almost nothing is measured.** §7 is what would change that.
- **IGL2 — A mandated database pulls state away from what makes the appliance good.** If
  approvals and the audit record live in an external database, the appliance's strongest
  property — a rollback that does not un-say the record (D10) — applies to a tier that no
  longer holds it. Open question 2.
- **IGL3 — Two records must not drift.** The application records intent; the machine records
  what ran (AU5). If they disagree, one is wrong, and nothing currently says which or
  detects it.
- **IGL4 — The worker is effectively a tier-0 asset.** A host permitted to create directory
  accounts is as valuable as the directory. AUL8 in the automation plan names this and builds
  nothing for it.
- **IGL5 — "Generic" is a claim that decays.** IG2 and IG9 are checkable in principle — could
  a new connector be added without touching the core — and no such check is written. Until
  one is, §2 is a paragraph, and P2-time is the standing reminder of what those are worth.

---

## 6. Open questions

1. **Which connector is second.** Active Directory is first because the knowledge exists
   (§1). The second one is the real genericity test, and picking a deliberately unfamiliar
   system is the honest choice.
2. **Where the record of truth lives**, if a deployment mandates a particular database. A
   two-tier store — business data in that database, the execution journal local and durable —
   is possible, and it is a design decision that must be made openly rather than discovered.
3. **Whether the journal's schema is a contract.** If the application reads the machine's job
   journal, it is one, and it needs a version field from the first line ever written (AU5,
   automation open question 4).
4. **How much of the machine's own surface the application exposes.** A worker on OS/7 could
   show boot environments and backup state in its own UI. Useful — and the first step back
   toward being an OS feature, which IG1's boundary has to hold against.

---

## 7. Measurements owed before any of this is called Decided

- **M-IG1 — a SQL Server client from .NET on resolute**, with SQL authentication and with
  Kerberos. Decides the shape of any relational connector and of the application's own store.
  Container, minutes.
- **M-IG2 — the DirSync LDAP control through `System.DirectoryServices.Protocols`** against a
  real Windows Server domain controller. Decides whether directory change tracking is cheap
  (a control) or expensive (full enumeration) — that is, whether IG10 scales.
- **M-IG3 — Microsoft Graph and the Exchange Online module, app-only, from Linux.** Needs a
  tenant; decides the whole cloud half of [IAM-SCOPE.md](IAM-SCOPE.md).
- **M-IG4 — SPNEGO against an ASP.NET Core application on Linux, with a keytab from a real
  domain controller.** Decides IG1's sign-on story.
- **M-IG5 — Exchange on-premises management from Linux.** The expectation is that the
  supported path no longer exists; that is an expectation and not a measurement, and it
  decides whether a Windows-side component is optional or mandatory.
- **M-IG6 — a plan that survives.** Produce a plan, restart every tier, apply it, and require
  the result to match what the plan said. IG6 is otherwise a noun.
