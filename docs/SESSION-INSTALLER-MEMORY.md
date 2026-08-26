# Session — the setup medium ran out of memory, and the bar that could not say so

**2026-08-26, from Windows.** No VM was booted and no ISO was built by this
session. Everything below is either read out of the **shipped**
`out/OS7-1.0.0.95-amd64.iso`, or run as code, or reported from a screen.

This is the first install this repository has heard about on **amd64**. HANDOFF
says of amd64 "nothing past the menu is measured"; this is a report from past
the menu, and it is a failure.

---

## 1. What was reported

A Hyper-V generation 2 VM — 6 GB RAM, 64 GB disk — booting the Install entry of
`OS7-1.0.0.95-amd64.iso`. Setup reaches **"Creating the ZFS pools and
datasets", 25%**, and the kernel starts killing processes at 258 s and has
`systemd:1` blocked for 122 s by 492 s. Both screens show the kernel's messages
painted across Setup's own screen.

25% is not a coincidence and it is worth writing down, because it identifies the
step exactly: the old bar was `done * 100 / steps.Count` over **16** steps, and
`PoolsAndDatasetsStep` is the fifth. 4/16 = 25%.

## 2. What was measured, and how

The squashfs was taken off the ISO and read in a container. No boot, no VM,
about four minutes:

```bash
bsdtar -xOf out/OS7-1.0.0.95-amd64.iso casper/filesystem.squashfs > fs.squashfs
unsquashfs -d x fs.squashfs /etc/systemd/system /usr/lib/sysctl.d \
                            /etc/modprobe.d /etc/apt/apt.conf.d /var/lib/dpkg/status
```

| Question | Answer, from the shipped image |
|---|---|
| the squashfs | 3 081 286 790 bytes, **gzip**, built 2026-08-25 19:52:27 |
| what `multi-user.target` starts | **39** units — `unattended-upgrades`, six `snapd` units, `packagekit`, `cups`, `cups-browsed`, `avahi-daemon`, `sssd`, `openvpn`, `rsyslog`, `sysstat`, `apport`, `whoopsie`, `ubuntu-advantage`, `casper-md5check`, … |
| timers | **15**, including `apt-daily.timer` and `apt-daily-upgrade.timer` |
| what `apt-daily` would do | `/etc/apt/apt.conf.d/10periodic`: `APT::Periodic::Update-Package-Lists "1"` |
| ZFS module options | **none at all** in `/etc/modprobe.d` or `/usr/lib/modprobe.d` — so `zfs_arc_max` is the default, half of physical memory |
| does anything reset the console loglevel | **yes** — `/usr/lib/sysctl.d/55-console-messages.conf: kernel.printk = 4 4 1 7` |
| is `unattended-upgrades` installed | yes; so are `snapd`, `packagekit`, `networkd-dispatcher`, `gdm3`, `update-notifier-common` |

The last row is the one that changes a comment in the repository from true to
false: `build/lib/efi-remaster.sh` said `quiet loglevel=0` was the kernel dealt
with. `systemd-sysctl` overrules it during boot, which is why an out-of-memory
cascade was legible only as a photograph.

Full analysis and the fixes: **[BUILD-NOTES #79](BUILD-NOTES.md)**.

## 3. The progress bar, and why it is in the same session

The bar and the crash are the same complaint from the operator's side: *the
screen stopped saying anything and then something went wrong.* The old bar
moved once per step, in 6.25% jumps, and stood still for the whole of whichever
step was running — minutes, for the copy and the initramfs.

It is now weighted (`IStep.Weight`), it uses a step's own figure where a step
can count its own work (`IStep.Percent`; `unsquashfs` can), and inside every
other step it advances on an estimate whose **seconds-per-weight scale is
measured during the run itself** — the elapsed time over the weight already
completed — so a slow machine gets a slow creep without anything being told what
hardware it is on.

The arithmetic lives in `Screens/ProgressModel.cs` and **not** in
`ExecuteScreen`, because constructing an `ExecuteScreen` starts a thread that
partitions a disk and so the self-test could never make one. `--self-test` now
walks the real step list at the screen's own 200 ms tick and reports the longest
the number stands still. That turned the shape of the creep from a preference
into a measurement, and the first two candidates lost:

| within-step estimate | worst stall, same simulated 22-minute install |
|---|---|
| `1 - e^(-t/tau)`, tau = expected duration | 34.0 s |
| `1 - e^(-t/tau)`, tau = expected duration / 3 | 53.8 s |
| `t / (t + expected/2)` | 50.8 s |
| **linear over the expected duration, then a bend** | **19.0 s** |

The surprise is the second row: making the bar climb *faster* made it stand
still *longer*. The stall was never in the climb — it is in the tail, where a
curve that has given up its rate has nothing left to say precisely while a step
is overrunning and somebody is watching. A constant rate has no tail to give up.
About 12 s is the floor for any of this, because 100 integer points over twenty
minutes is 12 s a point however they are distributed.

The old bar, for comparison, changed **16 times** in that twenty minutes.

## 4. What is checked, and by what

```bash
# no VM, no ISO — 20 new checks among the rest, all green
docker run --rm -v "$PWD":/work os7-build:amd64 bash -c \
  'cd /work/installer/src/OS7.Setup && dotnet publish -c Release -r linux-x64 \
   -p:PublishAot=true -o /tmp/pub && /tmp/pub/os7-setup --self-test'
```

* `/proc/meminfo` parsing, including that a **prefix is not a key** — "Mem"
  must not answer for "MemTotal", which on the machine in this note is wrong by
  a factor of thirty
* the ARC ceiling: 5.8 GiB → **742.6 MiB**, floor at 128 MiB, ceiling at 1 GiB,
  and an unreadable meminfo does not become an unlimited ARC
* that `InstallerEnvironmentStep` is **step 0** of both `--storage-only` and a
  full install, and that it precedes `PoolsAndDatasetsStep` — a ceiling on the
  ARC is worth nothing once the ARC has grown
* the bar: never backwards (including when its inputs go backwards), never into
  the next step's slice, exactly 100 at the end, and the stall bound above

The generator's gate is checked by **running it**, in
`build/config/hooks/0070-installer-quiesce.hook.chroot` at build time and once
by hand here:

| `/proc/cmdline` | units masked |
|---|---|
| `… boot=casper os7.setup=1 quiet` | **62**, each a symlink to `/dev/null` |
| `… boot=casper quiet splash` | **0** |
| `… noos7.setup=10 quiet` | **0** |
| `os7.setup=1x quiet` | **0** |

## 5. What this session did NOT do

* **No ISO was built and no machine was installed.** Every claim about the fix
  is a claim about code and about a squashfs.
* **The floor is still unmeasured.** `InstallerEnvironmentStep` *warns* below
  4 GiB rather than refusing, because nobody has established the real minimum.
  Refusing on a number nobody has measured would stop installs that work.
  SETUP-PLAN L33.
* **Whether that VM had 6 GB was never established.** Hyper-V's Dynamic Memory
  hands a guest its startup allocation and grows it only if the guest onlines
  what the balloon hot-adds, so "configured with 6 GB" and "MemTotal says 6 GB"
  are different sentences. `Get-VM` needs Hyper-V Administrator rights this
  session did not have. It is why the step logs `MemTotal`.
* **`casper-md5check` and `cloud-init` were left alone**, deliberately, and
  neither has been measured. The first re-reads the whole 3.26 GB medium at
  every install boot and is the only thing that catches a bad USB stick; the
  second is not implicated in the OOM and casper's relationship with it is not
  understood here.

## 5a. What `check-image.py` said about the amd64 ISO on the way past

`check-image.py` grew three checks for the generator, two notes for the image
facts #79 rests on, and — because it had to be run to prove those checks check
anything — **it was run against `OS7-1.0.0.95-amd64.iso` for the first time on
Windows**. Two things came out of that which are nothing to do with memory.

**The harness was broken on this host, twice, and both are BUILD-NOTES #70's
family.** `bash -n <path>` was being handed a Windows temp path it cannot open,
so all seven generated chroot scripts came back "No such file or directory" —
seven failures that look like seven broken scripts and are one broken harness.
Feeding the script on stdin fixed that and produced the second one: Python opens
a text-mode pipe on Windows and turns every newline into CR-LF, so `bash -n`
then reported `syntax error near unexpected token $'do\r'` about scripts that
are fine. It is fed **bytes** now. Both checks pass.

**And the probe could die without saying anything.** `set -e` is at the top of
it, so a self-test that exits non-zero killed the run *before* the `EXIT=$?`
line both readers depend on — with its output already redirected into a file, so
nothing reached stderr either. `check-image.py` then printed "could not read the
image" and an empty explanation, about an image it had already finished reading.
The comments on both blocks already said only the VERDICT may fail an image;
`&& rc=0 || rc=$?` makes the code do what they say.

**What the amd64 ISO then turned out to be.** These are properties of the
artefact and none of them is this session's to fix, but nobody has looked before
— HANDOFF says amd64 has only ever been built in CI:

| | |
|---|---|
| `dotnet-sdk-10.0`, `dotnet-sdk-aot-10.0` | **in the image** — CURATION-AND-DELIVERY-PLAN C2 says they leave |
| `linux-headers-*`, `linux-generic` | **in the image** — §4.2 and BUILD-NOTES #62 say they leave |
| `sanoid`, `syncoid`, the OS/7 backup units | **absent** |
| the GUI mode script's own proof | **absent** — that binary predates it |

The first two are most of why this ISO is **3.26 GB** against arm64's 1.83 GB,
and all four say the same thing: the curation and the features landed on arm64
and the amd64 image has not been rebuilt since. That is worth knowing before the
next amd64 build, and it is exactly what `check-image.py` is for.

## 6. Do this next, in order

1. **Rebuild amd64 and install into the same VM.** That is what settles all of
   it. Then read `/var/log/os7-setup/install.log` on the installed machine: it
   now carries MemTotal/MemAvailable/Shmem/SwapTotal before the first step,
   every step's real duration, the MemAvailable either side of it, and the ARC
   ceiling **read back out of sysfs**.
2. **Correct the weights from that log.** `IStep.Weight` is a table of
   estimates and is documented as one; the durations in the log are what it
   should have been. Nothing but the bar depends on them.
3. **Confirm the VM's memory** before blaming anything else, from an elevated
   PowerShell on the host:
   `Get-VM OS/7-Test | Select-Object MemoryStartup, MemoryAssigned, DynamicMemoryEnabled`
4. **Make the heavy uncounted steps count their own work.** `InitramfsStep` and
   the headless branch of `InstallModeStep` are the two that still rely on an
   estimate; `apt-get` can report progress on a status fd, which would make
   about a third of the bar evidence instead of arithmetic.
