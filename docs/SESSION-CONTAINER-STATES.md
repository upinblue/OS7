# Session — what OS/7 concludes about a container (CONTAINERS-PLAN step 3)

**2026-10-29, x64 Windows host.** The product layer over `powershell/Docker/`: CT6 (which
containers need attention), CT8 (who can reach a published port), P6 (configured beside
effective) and CT5's refusal, with a check that drives them against a fake engine. Plan:
[CONTAINERS-PLAN.md](CONTAINERS-PLAN.md) §6 step 3.

## What exists now

| Piece | What it is |
|---|---|
| `powershell/OS7-pending/OS7.Container.ps1` | `Get-OS7Container` (attention by default, `-All`, `-Name`), `Get-OS7ContainerLog`, `Start-`/`Stop-`/`Restart-`/`Remove-OS7Container`. No call to the engine except through `powershell/Docker` |
| `powershell/OS7-pending/README` | Why it is not in `powershell/OS7/` yet, and what wiring it in takes |
| `installer/testing/check-container-logic.py` | 86 checks against a fake engine at the Docker module's own seam; `--prove` plants seven defects in copies and requires each to go red |

**Not wired into the OS7 module, by the owner's choice.** Wiring means naming the file in
four lists (`OS7.psm1`, hook 0060, `build-os7-packages.sh`, `OS7.psd1`) and raising three
counts. Another session had `OS7.psm1`, `build-os7-packages.sh`, `CLAUDE.md` and `HANDOFF.md`
open and uncommitted, and the owner chose to build here and wire in afterwards rather than edit
them underneath it. `check-module-parts.py` scans `powershell/OS7/OS7.*.ps1` only, so the
pending file cannot turn it red for anybody, and it stays GREEN.

## The decisions, as the check holds them

**CT6 — 19 situations, 7 of them needing attention.** Each one is the RECORDED inspect object
of a real container on the archive's engine (`engine-29.1.3.jsonl`), with State, HostConfig and
NetworkSettings rewritten. The shape is the engine's, and only the situation is constructed.

| State | Attention | The rule |
|---|---|---|
| Running, Starting | no | running; a health check not yet decided is not a problem |
| Unhealthy | **yes** | running, and its own health check says unhealthy |
| RestartLoop | **yes** | the engine says `restarting` |
| OutOfMemory | **yes** | OOMKilled — **checked before the signal rule**, because the kernel's kill leaves 137 too |
| StartFailed | **yes** | not running, and the engine recorded an error starting it (port taken, mount missing) |
| Failed | **yes** | exited with a code that is neither 0 nor a signal's |
| Stopped | no | exit 0, **or 130/137/143** — what `docker stop` leaves behind |
| Created, Paused, Removing | no | never started; frozen on purpose; being removed |
| Dead | **yes** | the engine's own word for one it could not clean up |
| Unknown | **yes** | a status this file does not know |

**Two of CT6's first-draft rules did not survive being written down.** Both are corrected in the
plan:

- **"Stopped while the restart policy says `always`" was going to be an attention state, and it
  would have been wrong nearly every time.** An `always` container that crashes is restarted by
  the engine itself, so one standing still has been stopped by somebody. The API does not say
  who (the daemon keeps that flag internal), so the rule would fire on every deliberate stop. What
  *is* reliable is `State.Error`: the engine records why it could not start a container, and
  that is **StartFailed**.
- **"RestartCount rising" needs two readings over time.** That is polling, which G10 forbids, and
  a count of three over a year is not a loop. The engine's own `restarting` decides, and the
  count is reported beside it.

**CT8 — the bind address decides, in four answers.** `0.0.0.0`, `::` and an **empty** address all
mean every network. `0.0.0.0` and `::` of the same port are **one** entry, because the engine
lists a port published everywhere twice. Loopback means this machine only, anything else that
one address. A container on the **host network** publishes nothing, and every port it opens is
the machine's own, so it gets a sentence rather than an empty list. The words say what a port is
BOUND to; **whether a firewall also stands in front of it is O-M2 and unmeasured**, and nothing
claims otherwise.

**P6.** `RestartPolicy` beside `State`, and `PortsConfigured` (HostConfig) beside `Ports`
(NetworkSettings, only populated while running). A stopped container has the first and not the
second, and the check requires both to be shown.

**CT5.** As a user, a read reaches the socket, is refused, and comes back as #148's sentence:
*"Get-OS7Container must run as root … sudo Get-OS7Container DOES NOT WORK … sudo pwsh
-NoProfile -c 'Get-OS7Container <parameters>'"*. It is refused **after** the attempt, not by
uid, because an administrator who put themselves in `docker` has made a choice (O-CT3) that a
uid check would overrule. The lifecycle verbs call `Assert-OS7Elevated` first; the check
replaces that guard with a recorder and requires each verb to call it by its own name.

**Remove — CT10 corrected.** The plan said removal would *"refuse when volumes are attached"*.
That protects the wrong thing: named volumes **survive** a container's removal, and so do
anonymous ones unless `-RemoveVolumes` is given. What a remove destroys is the container's
writable layer, which CT3 deliberately keeps out of the backup. So `Remove-OS7Container` has
`ConfirmImpact High`, the engine refuses a running container without `-Force` (in its own words,
which the check requires), and the result lists **`KeptVolumes`** by name. A guard on the
writable layer itself needs the engine's `/containers/{id}/changes`, which the Docker layer does
not read yet. That guard is owed.

## What the check found while it was being written

- **The Compose project was never read.** The label's key is `com.docker.compose.project`, the
  field reader splits paths on dots, and so it walked `com` → `docker` → `compose` → `project`
  and found nothing. The window's *Applications* node would have stayed empty without a word.
  Fixed by reading a label as one name.
- **A verdict's `Command` for Paused was a sentence**, not something to type. The check parses
  every `Command` with PowerShell's own parser and requires each command to exist with the
  parameters it names (#127's shape). Found before it ran; the guidance moved into `Reason`.

## Proven to fire — `check-container-logic.py --prove`

Each defect is planted in a copy, and each one has to turn a named case red:

| Planted | Red |
|---|---|
| OOM read after the signal rule | 3, `cache: OutOfMemory` among them |
| a stop's exit code read as a failure (the attention view crying wolf) | 5 |
| `::` read as one address | 2 |
| the default view shows everything | 1 |
| an unknown status called fine | 2 |
| the start-failure rule removed | 2 |
| the read refusal without the elevation form | 1 |

## Checks around it, on the tree as it stands

`check-container-logic.py` GREEN (86), `--prove` 7/7 red; `check-ps-traps.py` all six held over
31 files (the pending file among them); `check-layering.py` 8 rules held, and P2-docker held on
the pending directory itself (asked by the check, via `OS7_LAYER3`); `check-module-parts.py`
GREEN; `check-privilege.py` holds; `Test-DockerModule` 58/58.

## Deviation from the plan, and why

Step 3 named *"a fake engine: an HTTP server on a Unix socket replaying the fixtures"*. It is
the Docker module's own replay seam instead. The socket was already measured live, against the
real engine as root and as a user (M-CT11, M-CT12). A fake server would be a second imitation of
the engine's HTTP behaviour in a second language, which is the kind of second copy §3 exists to
avoid. The seam runs the cmdlets whole; only the socket is replaced.

## Wired in, the same day

Once the other session had committed, `powershell/OS7-pending/` was emptied into the module and
deleted:

- `OS7.Container.ps1` is in `powershell/OS7/` and named in all four lists — `OS7.psm1` (after
  `OS7.Automation.ps1`), hook 0060, the `os7-module` .deb's required paths and `OS7.psd1`, whose
  six new exports hook 0060 now requires by name.
- **The Docker module ships with it**, which the plan had left for step 5. The container cmdlets
  import it, and a product cmdlet whose generic layer is missing answers an operator with "module
  not found". It is in `build.sh`'s fixture loop, the package loop and its required paths, hook
  0060 (every export, and at least two engine recordings), `check-image.py` (`Test-DockerModule`
  on the finished medium — so an ISO built before this fails that line by name, which is how the
  Hardware module arrived too), `check-module-parts.py` and `run-surface.py`. The handbook's
  generator was left alone on purpose: the manual describes what an operator can do, and with no
  engine on any image nobody can manage a container yet.
- The counts, asked of the modules: **OS7 176, Docker 12, 313 in eight modules**.
  `check-module-parts.py` went red on exactly six lines before the documents moved, and GREEN (39)
  after.

## Not done

- **The writable-layer guard** on remove (`/changes`).
- **No machine has run these cmdlets.** They have run against a fake built from a recording,
  and the Docker layer under them has run on a machine. The first real run is step 4's, on the
  bench's `ct3-docker` snapshot.
