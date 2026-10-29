# Session — the generic Docker layer (CONTAINERS-PLAN step 2)

**2026-10-29, x64 Windows host.** Built `powershell/Docker/`, recorded it against two real
engines, and added P2-docker to `check-layering.py`. Plan:
[CONTAINERS-PLAN.md](CONTAINERS-PLAN.md) §6 step 2, which is CT4 made into code.

## What exists now

| Piece | What it is |
|---|---|
| `powershell/Docker/Docker.psd1`, `Docker.psm1` | Layer 2: `Get-DockerEngine`, `Get-DockerContainer`, `Start-`/`Stop-`/`Restart-`/`Remove-DockerContainer`, `Get-DockerContainerLog`, `Get-DockerImage`, `Get-DockerVolume`, `Get-DockerNetwork`, `Get-DockerDiskUsage`, `Test-DockerModule`. Knows nothing about OS/7 |
| `Invoke-DockerApi` (internal) | The ONE function that reaches the engine: `Invoke-WebRequest -UnixSocket`, the negotiated `/vX.Y` prefix, the replay seam, the recorder. **Not exported**, for P2-hardware's reason |
| `Invoke-DockerFixtureScenario` (internal) | ONE sequence of requests, used by the capture to record and by the self-test to replay. No second copy to drift (#66) |
| `powershell/Docker/tests/fixtures/engine-*.jsonl` | Two recordings: the archive's `docker.io` 29.1.3 (API 1.52) on an installed OS/7 machine, and Docker Desktop 29.7.2 (API 1.55) |
| `installer/testing/capture-docker-fixtures.py` | `desktop` and `bench <name>`. Refuses to write a recording containing this host's user name or a Windows path, because the files are public |
| `check-layering.py` P2-docker | The eighth rule, at 0. Programs (`docker`, `dockerd`, `containerd`, `ctr`, `runc`, `nerdctl`, `podman`, `buildah`) **and** a second pattern for the way round a module that speaks HTTP: `-UnixSocket`, `docker.sock`, `containerd.sock`. `OS7_LAYER3` points the scan at a copy |

**Not shipped, on purpose.** The module is in none of the four lists that ship a module
(`build.sh` line 338, `build-os7-packages.sh` line 795, `check-module-parts.py` `MODULES`,
`run-surface.py` `MODULES`), so the module counts in CLAUDE.md, HANDOFF.md and
POWERSHELL-REFERENCE.md are untouched, and `check-module-parts.py` stays green (36 ok). It joins
those lists with the engine, in step 5.

## What was measured

| # | Finding | How |
|---|---|---|
| **M-CT11** | **The replay passes against both engines: 58 checks on this host, 61 on the bench with `-Live`.** Start 204 → `Started`, start again **304 → `AlreadyRunning`**, stop 204 → `Stopped`, stop again **304 → `AlreadyStopped`**, restart → `Restarted`, remove → `Removed` and asked back 404, a second remove → `ItemNotFoundException` carrying the engine's *"No such container"*. Every versioned request carried the negotiated prefix: 1.52 against 29.1.3, 1.55 against 29.7.2 | `Test-DockerModule` in the tree on Windows pwsh 7.6.9; `Test-DockerModule -Live` on bench `ctr` (snapshot `ct3-docker`), as root, pwsh 7.6.5 |
| **M-CT12** | **A real permission denial reads as intended.** The same module, as the login account `os7admin` (not in `docker`): `System.UnauthorizedAccessException`, *"/var/run/docker.sock refused 'os7admin'. The socket is root:docker 0660 on purpose: holding it is equivalent to root and shows every container's environment, passwords included. Run this as root."* The self-test's case for this is a constructed exception; this is the one it stands for | `capture-docker-fixtures.py bench ctr`, which asks without `--sudo` after recording |
| **M-CT13** | **Logs arrive as `application/vnd.docker.multiplexed-stream`, as bytes**, on both engines (48 bytes for two lines). Decoding the body as text would lose which line was stderr; the demultiplexer marks `out-line` stdout and `err-line` stderr | The recordings |
| **M-CT14** | The default bridge reads `172.17.0.0/16` on Docker Desktop and **`10.213.0.0/24`** on the bench — the range M-CT10 set before the package. `Get-DockerNetwork` reports it, which is what CT7's collision check will read | The recordings |

### Each check proven to fire, on a copy

Every planted defect went into a copy in the scratchpad and never into the tree, because another
session is working in it.

| Planted | Result |
|---|---|
| `Start-DockerContainer` reports 304 as `Started` — what the CLI does | **2 FAIL** (one per engine): *"start again: the engine said 304, and the verb says AlreadyRunning [304 Started]"* |
| `$script:DockerApiOldest` widened to 1.50 with no recording | **1 FAIL**: *"the oldest API spoken is the oldest recorded [1.52 vs 1.50]"* |
| `& docker ps`, two `-UnixSocket` calls, a `$docker` variable and a comment, in a copy of `powershell/OS7` | **P2-docker FAIL, 3** — the three calls, not the variable and not the comment; exit 1 |

**The second plant found a defect in the self-test itself.** The first attempt at that plant
replaced *every* `[version]'1.52'` in the file, including the test's own literals, so three lines
went red and two of them were the plant's doing. Redone on the constant alone, it still turned
two lines red: the range check, as intended, and *"an OLDER engine is refused, naming both
versions"*, whose expectation was the literal `1.52`. Widening the range with a new recording is
the routine way this module is kept up to date, and that check would have failed on exactly that
routine. The negotiation checks are now written relative to `$script:DockerApiOldest` and
`$script:DockerApiNewest`, and the plant turns exactly one line red.

### The checks around it

| Check | Result |
|---|---|
| `check-ps-traps.py` | all six held, 30 files (the new module among them) |
| `check-layering.py` | 8 rules held, P2-docker at 0 |
| `check-module-parts.py` | GREEN, 36 ok — unchanged, because the module is not in `MODULES` |
| `check-privilege.py` | holds |

## Not done, and not measured

- **No create, exec, build, pull, prune or image/volume removal.** v1 operates what exists
  (CT10, CT12), and the product layer will say what it needs from this layer in step 3.
- **A TTY container's raw log stream** is handled (`raw-stream` → all stdout) and has not been
  recorded.
- **A 409** (removing a running container without `-Force`) is not in the recordings. The
  self-test checks the 400 path with a constructed response.
- **Ubuntu's 29.1.3 CLI exit codes** (O-M5). This layer does not use the CLI, so the
  question has stopped mattering to the design; it still stands as a fact nobody has read.
- **arm64**, and the Gui install mode.

## Owed elsewhere — not edited here, because another session has these files open

- **CLAUDE.md**: the command list (`Test-DockerModule`, `capture-docker-fixtures.py`), and
  *"check-layering.py holds all seven"*, which is now **eight**.
- **POWERSHELL-SURFACE-PLAN.md**: P2-docker beside the other layering rules.
