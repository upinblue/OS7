# Capability scope

What [IAM-PLAN.md](IAM-PLAN.md) covers, what it deliberately does not, and the technical
reason for each. Written 2026-09-14; nothing here is built.

**How to read this.** A capability is *in scope* only if it survives both tests in
IAM-PLAN §2 — it must be expressible generically, and it must not require a per-deployment
code change. Several entries below are therefore marked **Konfiguration**: the capability is
in the product, the convention is in a data file. That distinction is the whole design, and
an entry that quietly migrates from Konfiguration to code is the failure IG3 and IG9 exist to
prevent.

**Verdicts**

| | |
|---|---|
| **Kern** | the engine or the single web application |
| **Connector** | a connector, with no core change (IG2, IG7) |
| **Konfiguration** | a template, a rule, a mapping, a state machine — data, not code |
| **Teilweise** | partly, with the missing part named |
| **Nicht** | deliberately out of scope, reason below |

---

## Directory objects and structure

| Capability | | Notes |
|---|---|---|
| Create, modify, disable, unlock and delete directory accounts | Connector | |
| Create and modify groups, organisational units, and memberships | Connector | |
| Navigate nesting — principal in group, group in group, group members — by clicking | Kern | a view over IG5's derivations, not a separate graph store |
| Several directories at once, in one forest or across forests | Kern | IG8 — N connector instances, never a special case |
| Map source attributes to target attributes, for every connected system | Kern | IG7 — generated from two manifests rather than authored per system |
| Place a new account automatically by department, location or account type | Konfiguration | a placement rule (IG4) |
| Generate an initial credential honouring the target's own policy, and deliver it by a configurable channel | Kern | the policy is **read from the target** (IG10), never restated in our configuration |
| Derive the application's own roles from directory group membership | Kern | |

## Directory hygiene

| Capability | | Notes |
|---|---|---|
| Report accounts with no recent sign-in, empty groups, principals in no group | Kern | queries over observed state |
| Report orphaned security identifiers | Teilweise | in the directory yes; on file systems no — see *Out of scope* |
| Reconcile observed state on a schedule so stale data is bounded | Kern | IG10 — the cache carries an age, and an unread value never reads as unchanged |

## Cloud identity

Every row here depends on M-IG3 and none of it has been measured.

| Capability | | Notes |
|---|---|---|
| Cloud directory accounts: synchronised-from-on-premises and cloud-only | Connector | |
| All cloud group types, including nested membership | Connector | nesting resolution is IG5 |
| Assign licences and applications; report who holds what | Connector | including assignments that arrive **through a group**, which is exactly why IG5 is a core condition |
| Report guest principals holding a licence | Connector | |
| Report guest principals in a collaboration team | Connector | |
| Analyse collaboration-platform permissions, showing the path by which each principal is entitled | Teilweise | cloud yes; the on-premises server product no |
| Set collaboration-platform permissions | Teilweise | cloud only |

## Mail and collaboration

| Capability | | Notes |
|---|---|---|
| Naming convention, group type and placement for mail-enabled groups | Konfiguration | they are directory groups |
| Hide or show a generated group in the address book | Konfiguration | an attribute |
| Request access to shared mailboxes through self-service, with a configurable catalogue of what may be requested | Teilweise | mailboxes yes; public folders only as far as the cloud API exposes them (M-IG3) |
| A manager sets an absence message for a report, from organisation-wide templates | Connector | templates are data |
| Create mailboxes automatically, with the address from a generation rule or a recipient policy | Connector + Konfiguration | |

## Identity lifecycle

| Capability | | Notes |
|---|---|---|
| Joiner, mover and leaver through forms usable without knowledge of the target systems | Kern | |
| Import personnel data from an upstream system without programming, detecting joins, moves and departures automatically | Kern | a read-only authoritative connector plus the reconciler |
| Per-attribute **effective date** on import, so a change is processed before it takes effect | Kern | due work lives in the application's own store — **never a transient systemd timer**, which does not survive a reboot and fails silently (AUTOMATION-PLAN AU12) |
| Assign entitlements automatically from attributes, **and withdraw them when the attributes change** | Kern | the withdrawal half is why a reconciler exists and a workflow engine is not enough |
| Model lifecycle states (active, leave of absence, departed) with actions per state, without programming | Konfiguration | a state machine made of data |
| State-derived actions take precedence over rule-derived entitlements | Kern | a precedence rule in the reconciler, not in a workflow |
| Manage external persons with workflows that differ from employees' | Kern | IG3 — an attribute, not a second type |
| Change a person's state immediately or at a future date, from self-service | Kern | same due-work store as effective dates |

## Roles and desired state

| Capability | | Notes |
|---|---|---|
| Report an identity's individual assignments against those its roles imply, per identity and per department | Kern | **this is the capability IG5 exists for**; without carried derivations it cannot be built late |
| Align roles and identities against each other as a difference tool | Teilweise | as a difference and a proposal to a human, yes; as automatic role discovery, no |
| Role mining | Nicht | see below |

## Approvals

| Capability | | Notes |
|---|---|---|
| An approval stage between request and provisioning | Kern | IG6 — a plan that waits |
| Escalate to a named authority when a request is unanswered for a configured period | Kern | |
| Compose approval workflows without programming, over approver *positions* — the subject's manager, a department head, a resource owner, a named organisational function | Teilweise | workflows as data, yes (IG4, IG9); a **graphical** editor is its own product decision, and v1 is a form |
| Approve some entitlements in a request and refuse others, with a comment per decision | Kern | falls out of IG6: a plan is approvable line by line |
| Notify the holder of a task by mail | Kern | the application's own templates, not the machine's sink (AU11) |

## Attestation

| Capability | | Notes |
|---|---|---|
| Periodic review of existing assignments by the responsible owner | Kern | a plan that asks about the existing state instead of changing it |
| Scope a campaign by resource and by population; configure its interval; start it automatically; notify by mail | Kern + Konfiguration | |
| Start a campaign from an event — a department change, for instance | Kern | the same trigger that drives automatic withdrawal |
| Cover directory groups, mail, cloud directory, collaboration platforms, and application roles | Teilweise | everything except file system permissions |
| Cover applications, application roles and other resources | Kern | IG3 — `Resource` is generic; an application's roles are a connector |
| Certify everything for one identity, or everything on one resource, in a single action | Kern | |
| A read-only auditor role, online | Kern | IG1 — one permission model, a view is a permission |

## Separation of duties

| Capability | | Notes |
|---|---|---|
| Declare entitlements mutually conflicting, absolutely or conditionally | Kern | a validator over a plan (IG6) |
| A configurable exception process supporting four eyes | Kern | and the rule that IG14 rests on |
| Record every exception and every violation | Kern | IG6 plus the machine's own record (AU5) |
| List the exceptions currently in force | Kern | |

## Audit and internal authorisation

| Capability | | Notes |
|---|---|---|
| Record every change without gaps: requester and time, every approver and time, and every change made in a target system | Kern | the last clause is only honest under IG10 — you may claim what you read back, not what you sent |
| Role-based internal authorisation, scoped by location and department, down to **field level** for identity attributes, with view and edit distinguished | Kern | IG1 |

## Extensibility

| Capability | | Notes |
|---|---|---|
| Run the operator's own PowerShell | Kern | IG11 — out of process, on the machine's job contract |
| Pass every relevant parameter to that script automatically, with no manual step | Kern | one JSON document on stdin (AUTOMATION-PLAN AU3) |
| Integrate a service-desk system: raise tickets through its API to represent manual work, and synchronise their status back | Connector | the clearest demonstration that IG7's contract holds outside the directory |

## Platform and sign-on

| Capability | | Notes |
|---|---|---|
| Fully browser-based; nothing installed on a workstation | Kern | IG1 — and the reason this application does not touch G1 |
| No separation between administrative and self-service surfaces; control by permission alone | Kern | IG1 |
| Desktop single sign-on via Kerberos, with no second password prompt | Kern | M-IG4 |
| A second factor enforceable for selected principals | Kern | OIDC against the cloud directory |
| A relational database as the store | Kern | with IGL2 and open question 2 — a mandated external store moves the record away from the appliance property that protects it |

---

## Out of scope, and why

Named rather than omitted. Each of these is a defensible product in its own right; none of
them is a module.

**File system permission management.** Discovering, analysing and changing permissions on
network file shares — including the group models that go with it, directory creation and
renaming, effective-permission computation, and the cumulative reporting of deviations down
a tree.

Three technical reasons, any one of which is sufficient. From Linux, reading and writing
Windows access control lists over SMB is possible but the *effective permission* computation
is ours to build, at volume, against a tree of unbounded size. Scanning at that volume across
slow links needs an agent on the far side — a second deployable artifact on an operating
system this product does not run on. And "any file server that speaks SMB, including
appliances" is an open-ended compatibility promise, where each appliance vendor's permission
model is its own dialect.

**Windows event collection.** Synchronising security events into the store, consolidating
fragmented events into meaningful ones, arbitrary event identifiers, raw and rendered views,
querying all or selected domain controllers.

This is a high-volume ingestion and correlation pipeline — a different discipline with
different storage economics — and it needs the same Windows-side foothold as the item above.
Integrating with a system the deployment already has is the better answer.

**Exchange on-premises management.** The supported remote-management path is PowerShell
remoting over WinRM, which is not available from PowerShell on Linux. Expected rather than
measured (M-IG5), and it decides whether a Windows-side component is optional or mandatory.
The cloud service is in scope.

**Role mining.** Deriving candidate business roles from existing assignments is an
unsupervised clustering problem whose output quality is bounded by the consistency of the
input. A deployment whose historical assignments are inconsistent — which is the deployment
that wants role mining — receives confident and wrong proposals. The difference tooling under
*Roles and desired state* is the part that is honest without it.

**A password reset portal.** Deferred rather than refused. It has a security posture unlike
the rest of the application — an unauthenticated front door, identity proofing, a separate
deployment target — and IG1 already reserves it as the one separable door.

**A report designer.** Exports of what the application can show are in scope. A designer for
arbitrary reports is a product.
