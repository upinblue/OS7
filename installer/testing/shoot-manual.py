#!/usr/bin/env python3
"""
The pictures and the transcripts in docs/manual/ — taken from a machine.

The administrator manual shows what an operator sees when they type an OS/7
cmdlet. That is a claim like any other, so nothing in it is written by hand:
this boots an INSTALLED OS/7 disk with no medium attached, logs in the way a
person does, and records what the machine printed. Two artefacts per shot:

    docs/manual/transcripts/NN-name.txt   what the machine printed, verbatim
    docs/manual/images/NN-name.png        the same bytes, drawn with the
                                          machine's own console font

The rendering is the method out/screenshots/README.md describes for the
`console/` set, reused rather than reinvented: the serial line carries the same
characters and the same palette INDICES a virtual console would, so painting
them with the PSF the image ships (/usr/share/consolefonts/os7-console-16x32,
Cascadia Mono, D15) and the kernel's own sixteen colours gives the screen a
person sees. The renderer itself is out/screenshots/tools/os7shot.py, imported
with its container-time REPO constant repointed at this checkout; it is not
copied, so there is one implementation of it and not two.

WHAT IS REAL AND WHAT IS NOT. Every character on every picture came off the
machine's serial line, at the console's own 80x24 — 1280x768 with the 16x32
font, which is SETUP-PLAN §2.4's reference geometry. The only thing arranged is
a `Clear-Host` before each command, so a picture holds one command and not the
tail of the previous one.

    ./shoot-manual.py            boot .vm/manual and take every shot
    ./shoot-manual.py --render   re-render from saved transcripts, no VM

.vm/manual is a COPY of .vm/s5's installed disk, firmware variables and TPM
state — the machine run-s5.py's gate produced. Copying rather than booting the
original is deliberate: this run writes to the disk (it creates a boot
environment), and the gate's artefact is worth keeping.
"""
import importlib.util
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login          # noqa: E402
from vmarch import SoftTpm                          # noqa: E402
from vmscreen import Lab                            # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_IMG = os.path.join(REPO, "docs", "manual", "images")
OUT_TXT = os.path.join(REPO, "docs", "manual", "transcripts")

# The machine .vm/s5 left behind, and the account run-s5.py created on it.
PASSPHRASE = "os7-s5-passphrase"
PASSWORD = "os7-s5-password"
USERNAME = "os7admin"

# 80x24, AND IT IS NOT A PREFERENCE. The terminal this harness draws must be
# the same size as the one the guest believes it has, or every absolute cursor
# move replays into the wrong place. The first version set the guest to 100x30
# with stty: PowerShell's formatter took the 100 and PSReadLine went on
# positioning in 80x24, so the two disagreed INSIDE the guest and the pictures
# came out with the command at the bottom right of an empty screen. Left alone,
# everything agrees at the serial console's own 80x24 — which is also
# SETUP-PLAN §2.4's reference geometry.
COLS, ROWS = 80, 24

lab = Lab("manual", target_gb=0, nic=True)
TPMDIR = os.path.join(lab.dir, "tpm")
# UNCOMPRESSED, deliberately. os7shot's Font decompresses a .gz into /tmp,
# which does not exist on the Windows host this runs on; the PSF itself is the
# same 34 KiB either way.
FONT = os.path.join(lab.dir, "os7-console-16x32.psf")

PROMPT = r"PS [^\r\n]*>"


# ---------------------------------------------------------------------------
# The renderer, borrowed rather than copied.
#
# os7shot.py sets REPO = "/work" because it runs inside the build container.
# Rewriting that one line while loading it is what lets the same file serve a
# host run; the alternative was a second copy of a 700-line tool, which is the
# thing this repository's BUILD-NOTES #66 is about.
# ---------------------------------------------------------------------------
def load_renderer():
    src = os.path.join(REPO, "out", "screenshots", "tools", "os7shot.py")
    if not os.path.exists(src):
        return None
    text = open(src, encoding="utf-8").read()
    text = text.replace('REPO = "/work"', "REPO = " + repr(REPO))
    # Everything above `def main()` is the library half: the palette, the PSF
    # reader, the terminal and the renderer. Below it is a walk of os7-setup
    # that would run on import.
    head = text.split("def main()")[0]
    # os7shot.py runs on Linux, so it imports fcntl, termios, pty and select at
    # the top for its Session class — the half that drives a pseudo-terminal.
    # This host is Windows and has none of them, and none of them is reached by
    # Vt, Font, palette or render. Dropping the import lines is what lets the
    # SAME file render here; Session would raise NameError if it were used, and
    # it is not.
    head = "\n".join(ln for ln in head.splitlines()
                     if ln.strip() not in ("import fcntl", "import termios",
                                           "import pty", "import select",
                                           "import signal", "import tty"))
    spec = importlib.util.spec_from_loader("os7shot_host", loader=None)
    mod = importlib.util.module_from_spec(spec)
    mod.__dict__["__file__"] = src
    exec(compile(head, src, "exec"), mod.__dict__)
    return mod


def trim_echo(raw, command):
    """Everything the machine printed AFTER the command was typed.

    PSReadLine repaints the line being edited on every keystroke, and it does
    it with an ABSOLUTE cursor move to the row it believes the prompt is on —
    the bottom of the screen, because on the machine the screen is full. A
    terminal replaying only this slice starts empty, so every one of those
    moves lands on the wrong row and the picture comes out as a staircase of
    half-typed commands.

    `Remove-Module PSReadLine` does not stop it: the host brings it back for
    the next prompt. So the echo is dropped here instead. The cut is at the end
    of the LAST complete rendering of the command — the one that was on screen
    when Enter was pressed — so what is fed to the terminal is exactly the
    command's own output and the prompt that followed it.

    The command itself is therefore NOT in the picture, and the manual prints
    it in a code block immediately above each one. That is the honest trade:
    a reconstructed prompt line would be a drawing of something the machine
    did not send.
    """
    i = raw.rfind(command.encode())
    if i < 0:
        return raw
    j = raw.find(b"\n", i + len(command))
    return raw[j + 1:] if j >= 0 else raw


def render_transcript(mod, raw, path):
    """Draw one captured transcript the way the machine would have shown it.

    Returns the terminal, because its `text()` is the only honest transcript
    there is: the raw bytes with the escapes stripped out still contain every
    repaint. What the SCREEN held after the sequences were replayed is one
    copy, and it is what a person read.
    """
    vt = mod.Vt(cols=COLS, rows=ROWS)
    vt.feed(raw.decode("utf-8", "replace"))
    # The blank rows below the last line of output are cut. The screen had
    # them; a page in a manual does not want half of it to be black. Nothing
    # that was printed is removed — the cut is at the last row holding a
    # character, and never above it.
    used = 0
    for i, row in enumerate(vt.cells):
        if any(cell[0] != " " for cell in row):
            used = i + 1
    if used:
        vt.cells = vt.cells[:used]
        vt.rows = used
    font = mod.Font(FONT)
    red, grn, blu = mod.palette.arrays({})          # the kernel's own sixteen
    rgb = [(red[i], grn[i], blu[i]) for i in range(16)]
    mod.render(vt, font, rgb, path)
    return vt


# ---------------------------------------------------------------------------
# What to photograph.
#
# One list, in the order the manual uses them. A shot is (name, command); the
# command is typed at an elevated PowerShell prompt exactly as written, so what
# the manual prints as "type this" is the string that was typed.
#
# EVERY COMMAND FITS ON ONE LINE, and that is a constraint rather than a
# style: the prompt is 19 columns of an 80-column console, so a command past
# about 58 characters wraps — and PSReadLine repaints a wrapped line one
# character at a time, which replays as a staircase of half-commands. The
# pictures are of what fits.
# ---------------------------------------------------------------------------
SHOTS = [
    # -- identity and discovery
    ("10-get-os7version",        "Get-OS7Version"),
    ("11-get-os7version-list",   "Get-OS7Version | Format-List *"),
    ("12-modules",               "Get-Module -ListAvailable OS7,Zfs,Net,Time,Systemd"),
    ("13-be-commands",           "Get-Command -Module OS7 -Noun OS7BootEnvironment"),
    ("14-verbs",                 "Get-Command -Module OS7 -Verb Get -Noun OS7B*"),

    # -- storage
    ("20-get-zpool",             "Get-Zpool | Format-Table Name,Health,Size,Free"),
    ("21-zpool-status",          "Get-ZpoolStatus rpool | Format-List Name,State,Scan"),
    ("22-datasets",              "Get-ZfsDataset | Format-Table Name,Mountpoint"),
    ("23-space",                 "Get-ZfsSpace rpool | Format-List"),
    ("24-home",                  "Get-OS7Home | Format-List"),

    # -- boot environments
    ("30-boot-environments",     "Get-OS7BootEnvironment"),
    ("31-be-detail",             "Get-OS7BootEnvironment | Format-List *"),
    ("32-new-be",                "New-OS7BootEnvironment -Name demo"),
    ("33-be-after-new",          "Get-OS7BootEnvironment"),
    ("34-remove-be",             "Remove-OS7BootEnvironment -Name demo -Confirm:$false"),

    # -- updates
    ("40-get-release",           "Get-OS7Release"),
    ("41-test-update",           "Test-OS7Update"),
    # The #113 fix: the unattended update check is a TIMER, and the noun that
    # can see one is Get-OS7ScheduledTask (P9). A bare name implies the detail
    # lookup, and an object with more than four properties renders as a list.
    ("43-update-timer",          "Get-OS7ScheduledTask os7-update-check.timer"),

    # -- services and logs
    ("50-services",              "Get-OS7Service -OS7Only -Detailed"),
    ("51-one-service",           "Get-OS7Service -Name ssh.service -Detailed | Format-List"),
    ("52-log",                   "Get-OS7Log -OS7Only -Tail 5"),
    ("53-install-log",           "Get-OS7InstallLog | Select -Skip 4 -First 8 Message"),

    # -- scheduled tasks. The register command does not fit on one 58-column
    # line, so it is splatted over two — which is also the idiom the manual
    # teaches for any parameter set that has outgrown a line.
    ("54-scheduled-tasks",       "Get-OS7ScheduledTask | Format-Table Name,NextRun,LastRun"),
    ("55-task-detail",           "Get-OS7ScheduledTask sanoid.timer | Format-List"),
    ("56-register-a",            "$t = @{ Name='scrub'; Weekly=$true; DayOfWeek='Sunday' }"),
    ("57-register-b",            "$t += @{ At='03:00'; Command='Start-ZpoolScrub rpool' }"),
    ("58-register",              "Register-OS7ScheduledTask @t"),
    ("59-unregister",            "Unregister-OS7ScheduledTask scrub -Confirm:$false"),

    # -- network
    ("60-adapters",              "Get-OS7NetworkAdapter"),
    ("61-network-config",        "Get-OS7NetworkConfiguration | Format-List"),
    ("62-test-network",          "Test-OS7Network | Format-List Ok,HasLink,DnsWorks"),
    ("63-endpoints",             "(Test-OS7Network).Endpoints | Format-Table -AutoSize"),
    ("64-endpoint-list",         "Get-OS7Endpoint | Format-Table Name,Host,Port"),

    # -- time
    ("70-time",                  "Get-OS7Time | Format-List"),
    ("71-time-sync",             "Get-OS7TimeSynchronization | Format-List"),

    # -- remoting and management
    ("80-remoting",              "Get-OS7Remoting | Format-List"),
    ("81-management",            "Get-OS7ManagementStatus | Format-List"),
    ("82-entra",                 "Get-OS7EntraStatus | Format-List"),
    ("83-intune",                "Get-OS7IntuneEnrollment | Format-List"),
    ("84-arc",                   "Get-OS7ArcStatus | Format-List"),

    # -- backup
    ("90-backup-policy",         "Get-OS7BackupPolicy | Format-List"),
    ("91-backup-coverage",       "Get-OS7BackupCoverage | Format-List"),
    ("92-backup-status",         "Get-OS7BackupStatus -SkipTargets | Format-List"),
    ("93-backup-targets",        "Get-OS7BackupTarget"),

    # -- directory
    ("a0-domain",                "Get-OS7Domain | Format-List"),
    ("a1-admin-session",         "Get-OS7AdminSession"),
    ("a2-kerberos",              "Get-OS7KerberosTicket"),
]


def wait_prompt(c, after, timeout):
    """Wait for a prompt in everything the console printed past byte `after`."""
    rx = re.compile(PROMPT.encode())
    deadline = time.time() + timeout
    while time.time() < deadline:
        if c.proc.poll() is not None:
            raise SystemExit("the VM went away mid-run — is a second run of this "
                             "harness up? Both would use the container name "
                             "os7vm-manual, and the first one to finish removes it.")
        if rx.search(bytes(c.buf[after:])):
            return True
        time.sleep(0.2)
    return False


def capture(c, command, timeout=240):
    """Type one command and return the bytes from its prompt to the next one.

    CLEARED FIRST, so the picture holds this command and nothing else. Without
    it every shot carries the tail of the one before, and the reader has to be
    told which half to look at. The clear is a real Clear-Host on the machine,
    not a crop.
    """
    # THE SLICE STARTS BEFORE THE CLEAR, and that is the whole trick. Starting
    # it at the prompt AFTER the clear leaves the clear sequence outside the
    # slice, so the terminal that replays the slice never clears — and every
    # absolute cursor move that follows lands relative to a screen that is not
    # the one the machine had. The first version did that and produced pictures
    # with the command at the bottom right of an empty screen. Inside the
    # slice, the ESC[2J erases its own echo and everything after it is placed
    # exactly where the machine placed it.
    start = len(c.buf)
    c.send("Clear-Host")
    wait_prompt(c, start + len("Clear-Host"), 60)
    time.sleep(0.4)
    n_before = len(c.buf)
    c.send(command)
    # The next prompt, and NOT the echo of the command: the echo sits inside
    # the slice that begins at n_before, so the search is anchored past it.
    # BUILD-NOTES #16 is this trap in its other form.
    if wait_prompt(c, n_before + len(command), timeout):
        time.sleep(0.8)                          # let the prompt finish painting
    else:
        print("    TIMEOUT on: " + command, flush=True)
    return bytes(c.buf[start:])


def save(name, raw, mod, command=None, resave_raw=True):
    if resave_raw:
        with open(os.path.join(OUT_TXT, name + ".raw"), "wb") as f:
            f.write(raw)
    text = None
    if mod is not None:
        try:
            shown = trim_echo(raw, command) if command else raw
            vt = render_transcript(mod, shown, os.path.join(OUT_IMG, name + ".png"))
            text = "\n".join(line.rstrip() for line in vt.text().splitlines()).strip("\n")
        except Exception as e:                    # noqa: BLE001
            print("    note  could not render " + name + ": " + str(e))
    if text is None:
        # No renderer: the raw bytes with the escapes taken out, the way
        # run-s5.py's body_of() does it. Readable, but PSReadLine's repaints
        # are still in it.
        text = raw.decode("utf-8", "replace")
        text = re.sub(r"\x1b\][0-9;]*[^\x07\x1b]*(\x07|\x1b\\)", "", text)
        text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
        text = text.replace("\r", "")
    # LF EXPLICITLY: Python's text mode writes CRLF on Windows, and this file
    # goes into the repository beside transcripts written on a Mac. Without the
    # newline argument, re-shooting on this host rewrites the line endings of
    # every transcript, and the one line that actually changed hides in
    # fifty-four files of noise.
    with open(os.path.join(OUT_TXT, name + ".txt"), "w", encoding="utf-8",
              newline="\n") as f:
        f.write(text + "\n")


def shoot():
    mod = load_renderer()
    if mod is None:
        print("    note  out/screenshots/tools/os7shot.py is absent — transcripts only")
    for need in (lab.target, lab.vars):
        if not os.path.exists(need):
            raise SystemExit("missing " + need + " — copy .vm/s5's state into .vm/manual first")
    if not os.path.exists(FONT):
        raise SystemExit("missing " + FONT + " — extract it from an OS/7 image "
                         "(/usr/share/consolefonts/os7-console-16x32.psf.gz)")
    os.makedirs(lab.shots, exist_ok=True)

    p = lab.arch.path
    args = lab.arch.base_args() + ["-smp", lab.CPUS, "-m", lab.MEM] \
        + lab.arch.firmware_args(lab.vars) + [
            "-display", "none", "-monitor", "none", "-serial", "stdio",
            "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
            "-drive", "if=none,id=target,file=" + p(lab.target) + ",format=qcow2",
            "-device", "virtio-blk-pci,drive=target,serial=os7target",
        ]
    tpm = SoftTpm(lab.arch, TPMDIR, True)
    tpm.__enter__()
    c = Console(lab.arch.command(args + tpm.args(), name=lab.name, tpm=tpm),
                os.path.join(lab.dir, "manual.serial.log"))
    try:
        print("    booting the installed disk (no medium attached) …", flush=True)
        i = c.expect([r"\blogin:", r"passphrase", r"\(initramfs\)", r"Kernel panic"],
                     900, "a login prompt")
        if i >= 2:
            raise SystemExit("the machine did not start:\n" + c.text()[-2500:])
        if i == 1:
            # Not a finding about the product. run-s5.py's `boot` phase is
            # where the TPM claim is measured, on the disk and the swtpm state
            # that belong together; a COPY of both into another directory is a
            # different machine as far as the seal is concerned. This harness
            # is here for pictures, so it types the passphrase and says so.
            print("    note  the copied TPM state did not unseal — typing the")
            print("          passphrase. run-s5.py boot is where that is measured.")
            c.send(PASSPHRASE)
            c.expect(r"\blogin:", 900, "a login prompt")
        else:
            print("    ok    the TPM unlocked the disk — nothing was typed", flush=True)

        live_login(c, user=USERNAME, password=PASSWORD)
        c.answering = True
        c.expect(PROMPT, 180, "the PowerShell prompt an OS/7 login lands on")
        print("    ok    the login landed in PowerShell", flush=True)

        # The login screen itself, before anything is elevated: /etc/issue, the
        # MOTD OS/7 writes, and the prompt a person is left at.
        save("00-login", bytes(c.buf), mod)

        # THE TERMINAL IS LEFT AT ITS OWN SIZE — see COLS/ROWS above. An
        # earlier version ran `stty rows 30 cols 100` here and made the guest
        # disagree with itself.
        #
        # It also ran that stty under sudo, which needed no privilege and cost
        # a run: sudo printed a password prompt, the harness was not waiting
        # for one, and the NEXT COMMAND was typed into it. "sudo pwsh -NoLogo"
        # is seventeen characters and the log shows seventeen asterisks and
        # "Authentication failed" three times. Nothing said a command had been
        # eaten; the run simply never reached a prompt. BUILD-NOTES #16 again.
        #
        # `sudo pwsh` and not `sudo -i`: it is what an operator on this machine
        # actually types, and the manual shows the same line.
        c.send("sudo pwsh -NoLogo")
        j = c.expect([r"[Pp]assword:", PROMPT], 120, "sudo or a prompt")
        if j == 0:
            c.send(PASSWORD)
            c.expect(PROMPT, 180, "an elevated PowerShell prompt")
        time.sleep(3.0)

        # PSREADLINE GOES, and it is not a cosmetic choice. It repaints the
        # line being edited after every keystroke, and on this console it did
        # its cursor arithmetic in 80 columns while PowerShell formatted its
        # output for 100 — so the repaint landed twenty columns to the right
        # and overwrote the prompt it had just drawn. What is lost is syntax
        # colouring on the line being typed; the output's own colours are
        # PowerShell's and are untouched.
        c.send("Remove-Module PSReadLine -Force -ErrorAction SilentlyContinue")
        c.expect(PROMPT, 90, "a prompt without PSReadLine")
        time.sleep(1.0)

        c.send("Import-Module OS7")
        c.expect(PROMPT, 240, "the OS7 module")
        print("    ok    elevated PowerShell, OS7 imported\n")

        for name, command in SHOTS:
            raw = capture(c, command)
            save(name, raw, mod, command)
            print("    {0:28s} {1:6d} bytes".format(name, len(raw)), flush=True)

        c.send("exit")
        time.sleep(1.5)
        c.send("sudo systemctl poweroff")
        time.sleep(25)
    finally:
        c.close()
        tpm.__exit__()


def rerender():
    mod = load_renderer()
    if mod is None:
        raise SystemExit("out/screenshots/tools/os7shot.py is absent — nothing to render with")
    for fn in sorted(os.listdir(OUT_TXT)):
        if fn.endswith(".raw"):
            name = fn[:-4]
            raw = open(os.path.join(OUT_TXT, fn), "rb").read()
            command = dict(SHOTS).get(name)
            save(name, raw, mod, command, resave_raw=False)
            print("    re-rendered " + fn[:-4])


def main():
    os.makedirs(OUT_IMG, exist_ok=True)
    os.makedirs(OUT_TXT, exist_ok=True)
    if "--render" in sys.argv:
        rerender()
    else:
        shoot()


if __name__ == "__main__":
    main()
