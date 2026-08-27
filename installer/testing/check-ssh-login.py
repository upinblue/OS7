#!/usr/bin/env python3
"""
What an SSH login to an OS/7 machine actually lands in — against a real sshd.

    ./check-ssh-login.py                     find an os7img:* image and use it
    ./check-ssh-login.py --image os7img:116  use this one

WHY IT EXISTS. Two separate claims, both about the headline experience of this
product, and until 2026-08-27 NEITHER had ever been tested by anything:

  1. `ssh os7box` lands in PowerShell. That is /etc/profile.d/95-os7-powershell.sh
     (hook 0050) handing an interactive LOGIN SHELL over to pwsh. Hook 0050
     proves the drop-in fires by piping into `bash --login -i`, which is a good
     check of the drop-in and says nothing about sshd — the guard that matters
     most, `SSH_ORIGINAL_COMMAND`, cannot even be exercised that way.

  2. `Enter-PSSession -HostName os7box` works. That is a different mechanism
     entirely: sshd starts a SUBSYSTEM and no login shell runs at all. It was
     simply absent — `sshd -T` on the shipped image listed `sftp` and nothing
     else — so every one of those calls failed with "subsystem request failed".

WHAT MAKES THIS A TEST AND NOT A DEMONSTRATION. The subsystem case is checked
BEFORE and AFTER `Enable-OS7Remoting`. A check that only ran afterwards would
pass just as happily against a machine where the drop-in was irrelevant, and
this repository has paid for that shape more than once — a hook that reported
success for something it never caused (#13), a package list that removed nothing
(#62), a theme installed and never loaded (#85).

THE THIRD CLAIM IS THE ONE NOBODY THINKS OF. `ssh host 'command'`, scp, sftp and
git-over-ssh must NOT get PowerShell. The drop-in guards against it twice, and
if either guard went the failure would not be a PowerShell prompt — it would be
every file copy to the machine breaking, with no obvious connection to a shell
setting.

WHAT IT NEEDS. An OS/7 image as a container image: this wants the real
/etc/profile.d drop-in, the real pwsh and the real sshd_config together, and
those exist as an artefact rather than as files in the tree. Without one it
reports NOT CHECKED rather than skipping quietly — "cannot tell" is not "clean".
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


def find_image(explicit):
    if explicit:
        return explicit
    try:
        out = subprocess.run(["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    # Newest first is what `docker images` gives; take the first os7img.
    for line in out.splitlines():
        if line.startswith("os7img:"):
            return line.strip()
    return None


# The whole thing in one container: bring up sshd, log in as an ordinary user,
# and ask what answered. Everything is asked of the SESSION rather than of a
# configuration file.
#
# THE MARKERS ARE GREPPED, NOT PARSED. An interactive PowerShell over a pty
# emits cursor-position queries and colour codes (BUILD-NOTES #16 is the same
# terminal reality from the installer's side), so the output is not a clean
# transcript and never will be. A marker either appears in it or does not.
SCRIPT = r"""
set -e
useradd -m -s /bin/bash os7admin 2>/dev/null || true
mkdir -p /run/sshd /home/os7admin/.ssh
ssh-keygen -A >/dev/null 2>&1
ssh-keygen -t ed25519 -N "" -f /root/k >/dev/null 2>&1
cp /root/k.pub /home/os7admin/.ssh/authorized_keys

# THE "BEFORE" STATE IS ESTABLISHED, NOT ASSUMED. Since the drop-in ships in
# build/config/includes.chroot, a NEWLY BUILT image already offers the
# subsystem -- so a check that took the image as it found it would report "no
# powershell subsystem to begin with" as a failure on precisely the image the
# fix shipped in, and would silently stop testing Enable-OS7Remoting at all.
# Removing it first makes the before/after real on any image, old or new.
rm -f /etc/ssh/sshd_config.d/60-os7-powershell.conf

/usr/sbin/sshd -p 2222
sleep 1

# THE KEY AND THE known_hosts GO IN THE USER'S OWN HOME, and that is not
# tidiness. PowerShell remoting starts `ssh` AS THE USER, so it reads
# ~/.ssh/known_hosts and not root's -- and with root's, New-PSSession fails
# with "Host key verification failed", which looks exactly like the failure
# this check is trying to attribute to a missing subsystem. A before/after test
# whose "before" fails for the wrong reason proves nothing.
ssh-keyscan -p 2222 127.0.0.1 > /home/os7admin/.ssh/known_hosts 2>/dev/null
cp /root/k /home/os7admin/.ssh/id_ed25519
chown -R os7admin:os7admin /home/os7admin/.ssh
chmod 700 /home/os7admin/.ssh
chmod 600 /home/os7admin/.ssh/authorized_keys /home/os7admin/.ssh/known_hosts \
          /home/os7admin/.ssh/id_ed25519

S="ssh -i /root/k -p 2222 -o UserKnownHostsFile=/home/os7admin/.ssh/known_hosts -o LogLevel=ERROR os7admin@127.0.0.1"

# Written to files rather than inlined: this text has to survive Python's
# formatting, bash's quoting and ssh's, and every layer that can eat a $ is a
# layer that can turn a real answer into an empty marker.
# THE MARKER IS ASSEMBLED, NEVER TYPED WHOLE. BUILD-NOTES #16, and this check
# fell into it on its first run: a pty ECHOES what is sent, so a grep for a
# marker the input contains matches the echo and reports success for a command
# that never ran. Concatenating it means the echoed line carries
# `"OS7MARK" + "-INTERACTIVE"` and only the OUTPUT carries the joined form.
cat > /tmp/probe.ps1 <<'PS1'
$m = "OS7MARK" + "-INTERACTIVE"
Write-Output "$m-$($PSVersionTable.PSVersion.Major)"
exit
PS1

# /tmp AND NOT /root: the remoting probe runs as os7admin via runuser, and
# /root is mode 700 - an unreadable script produced no output at all, which
# looked exactly like a subsystem that was not working.
cat > /tmp/remote.ps1 <<'PS1'
try {
    $s = New-PSSession -HostName 127.0.0.1 -Port 2222 -UserName os7admin `
        -KeyFilePath /home/os7admin/.ssh/id_ed25519 -ErrorAction Stop
    $v = Invoke-Command -Session $s { $PSVersionTable.PSVersion.Major }
    $r = Invoke-Command -Session $s { $null -ne $env:SSH_CONNECTION }
    Write-Output "OS7MARK-REMOTING-OK-$v-remote=$r"
    Remove-PSSession $s
} catch {
    Write-Output "OS7MARK-REMOTING-FAILED: $($_.Exception.Message)"
}
PS1
chmod 644 /tmp/probe.ps1 /tmp/remote.ps1

# EVERY STEP HAS A TIME BUDGET. An ssh that waits for a password, or a
# New-PSSession against a subsystem that is not there, hangs rather than
# failing -- and a check that hangs is worse than one that fails, because
# nobody learns anything and it gets killed instead of read.
# THE PROMPT IS THE EVIDENCE, not a command's output. Feeding a command into an
# interactive PowerShell over a pty does not work reliably -- PSReadLine reads
# keys rather than a stream, and BUILD-NOTES #16 is this repository's record of
# the same terminal reality from the installer's side. What is being claimed is
# "the session lands in PowerShell", and the prompt IS that claim.
#
# WITH A CONTROL. The same login is made twice: once as shipped, and once with
# the drop-in moved aside. Without the second run this would pass against a
# machine where the drop-in did nothing, which is the shape of #13 and #85.
echo "<<<interactive>>>"
printf 'exit\n' | timeout 30 $S -tt 2>/dev/null | tr -d '\r' || true

echo "<<<interactive-control>>>"
mv /etc/profile.d/95-os7-powershell.sh /tmp/dropin-aside
printf 'exit\n' | timeout 30 $S -tt 2>/dev/null | tr -d '\r' || true
mv /tmp/dropin-aside /etc/profile.d/95-os7-powershell.sh

echo "<<<command>>>"
timeout 20 $S 'echo OS7MARK-COMMAND-shell=$0 pwsh=${OS7_PWSH_ACTIVE:-unset}' 2>/dev/null || true

echo "<<<sftp>>>"
echo hello > /tmp/sftp-probe
printf 'put /tmp/sftp-probe /home/os7admin/sftp-probe\nquit\n' \
  | timeout 20 sftp -i /root/k -P 2222 \
      -o UserKnownHostsFile=/home/os7admin/.ssh/known_hosts -o LogLevel=ERROR \
      os7admin@127.0.0.1 >/dev/null 2>&1 && echo OS7MARK-SFTP-OK || echo OS7MARK-SFTP-FAILED

echo "<<<subsystem-before>>>"
/usr/sbin/sshd -T 2>/dev/null | grep -i '^subsystem' || true

echo "<<<remoting-before>>>"
timeout 60 runuser -u os7admin -- pwsh -NoProfile -NonInteractive -File /tmp/remote.ps1 2>/dev/null \
  | grep OS7MARK || echo OS7MARK-REMOTING-FAILED-no-output

echo "<<<enable>>>"
pwsh -NoProfile -NonInteractive -Command '
  Import-Module /work/powershell/OS7/OS7.psd1 -Force
  $before = Get-OS7Remoting
  "BEFORE Subsystem=[$($before.Subsystem)] Interactive=[$($before.InteractiveShell)]"
  $after = Enable-OS7Remoting -Confirm:$false
  "AFTER  Subsystem=[$($after.Subsystem)] Interactive=[$($after.InteractiveShell)]"
  "LINE   $($after.SubsystemLine)"
  "DETAIL $($after.Detail)"
' 2>&1 | grep -E '^(BEFORE|AFTER|LINE|DETAIL)' || true

# Enable-OS7Remoting reloads through systemctl, and there is no systemd here.
# sshd is restarted by hand so that the AFTER case tests the CONFIGURATION and
# not the absence of an init system.
pkill sshd || true
sleep 1
/usr/sbin/sshd -p 2222
sleep 1

echo "<<<subsystem-after>>>"
/usr/sbin/sshd -T 2>/dev/null | grep -i '^subsystem' || true

echo "<<<remoting-after>>>"
timeout 60 runuser -u os7admin -- pwsh -NoProfile -NonInteractive -File /tmp/remote.ps1 2>/dev/null \
  | grep OS7MARK || echo OS7MARK-REMOTING-FAILED-no-output
"""


def section(text, name):
    """One <<<name>>> block out of the container's output."""
    marker = f"<<<{name}>>>"
    if marker not in text:
        return ""
    rest = text.split(marker, 1)[1]
    end = rest.find("<<<")
    return (rest if end < 0 else rest[:end]).strip()


def main():
    ap = argparse.ArgumentParser(description="what an SSH login lands in")
    ap.add_argument("--image", help="an OS/7 container image, e.g. os7img:116")
    args = ap.parse_args()

    print("### what an SSH login to an OS/7 machine lands in")

    if not shutil.which("docker"):
        print("\n      NOTE  NOT CHECKED. docker is needed: this runs a real sshd.")
        return 0
    image = find_image(args.image)
    if not image:
        print("\n      NOTE  NOT CHECKED. No OS/7 container image found.")
        print("      NOTE  This wants the real /etc/profile.d drop-in, the real pwsh and")
        print("      NOTE  the real sshd_config together, which exist as an artefact and")
        print("      NOTE  not as files in the tree. Pass --image <tag>.")
        return 0
    print(f"### against {image}, with a real sshd on port 2222\n")

    p = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "", "-v", f"{REPO}:/work",
         image, "bash", "-c", SCRIPT],
        capture_output=True, text=True)
    out = p.stdout

    print("  ssh, interactively")
    def tail(text):
        """The LAST non-empty line — which is where the prompt is.

        The first 70 characters of an ssh session are the MOTD, which is
        identical whichever shell answers. A detail that cannot distinguish the
        two cases makes a passing control unreadable.
        """
        # ANSI stripped for READING only; the checks above look at the raw
        # text. An interactive PowerShell fills a pty with cursor-position
        # queries, which is informative about which shell answered and
        # unreadable as a detail string.
        clean = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b[()][A-B0-9]", "", text)
        lines = [l.strip() for l in clean.splitlines() if l.strip()]
        if not lines:
            return "(nothing came back)"
        prompt = [l for l in lines if "PS /" in l or l.rstrip().endswith("$")]
        return (prompt[-1] if prompt else lines[-1])[:70]

    inter = section(out, "interactive")
    check("PS /home/os7admin" in inter,
          "an interactive ssh login lands at a PowerShell prompt",
          tail(inter))
    # The control. Without the drop-in the SAME login must land in bash, or the
    # check above is passing on something the drop-in did not cause.
    ctl = section(out, "interactive-control")
    check("PS /home/os7admin" not in ctl,
          "and with the drop-in moved aside it does NOT",
          tail(ctl))
    check("os7admin@" in ctl,
          "it lands in bash instead — so the drop-in is what does it",
          tail(ctl))

    print("\n  ssh, with a command — scp, git and rsync take this path")
    cmd = section(out, "command")
    check("OS7MARK-COMMAND-shell=bash" in cmd,
          "`ssh host command` stays in bash", cmd.strip()[:70])
    check("pwsh=unset" in cmd,
          "and the hand-off did not fire for it")
    sftp = section(out, "sftp")
    check("OS7MARK-SFTP-OK" in sftp,
          "sftp still works — the subsystem that must not be broken")

    print("\n  Enter-PSSession, BEFORE the subsystem exists")
    # THE HALF THAT MAKES THIS A TEST. Without it, the "after" case would pass
    # against a machine where Enable-OS7Remoting changed nothing at all.
    before_sub = section(out, "subsystem-before")
    check("powershell" not in before_sub.lower(),
          "sshd offers no powershell subsystem to begin with", before_sub.replace("\n", "; "))
    check("OS7MARK-REMOTING-FAILED" in section(out, "remoting-before"),
          "and Enter-PSSession therefore FAILS")

    print("\n  Enable-OS7Remoting")
    en = section(out, "enable")
    for line in en.splitlines():
        print(f"            {line.strip()}")
    check("BEFORE Subsystem=[False]" in en,
          "Get-OS7Remoting reported the subsystem as absent")
    check("Interactive=[True]" in en,
          "and the interactive hand-off as present — two mechanisms, two fields")
    check("AFTER  Subsystem=[True]" in en,
          "and as present afterwards")

    print("\n  Enter-PSSession, AFTER")
    after_sub = section(out, "subsystem-after")
    check("subsystem powershell" in after_sub.lower(),
          "sshd -T now lists the powershell subsystem")
    check("sftp" in after_sub.lower(),
          "and still lists sftp — adding one did not replace the other")
    after = section(out, "remoting-after")
    check("OS7MARK-REMOTING-OK-7" in after,
          "Enter-PSSession works, and the far end is PowerShell 7",
          after.strip()[:80])
    check("remote=True" in after,
          "and it really is a remote session, not a local fallback")

    if p.returncode != 0 and not FAILS:
        print(f"\n      NOTE  the container exited {p.returncode}; stderr follows")
        print("            " + p.stderr.strip().replace("\n", "\n            ")[:900])

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        return 1
    print("all checks passed — an interactive ssh lands in PowerShell, a command "
          "does not, and Enter-PSSession works only once the subsystem is there.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
