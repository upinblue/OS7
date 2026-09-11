#!/usr/bin/env python3
"""
Every cmdlet that changes the machine refuses as a user, in a sentence.

    ./check-privilege.py            report, and fail if the rule got worse

WHY THIS EXISTS. BUILD-NOTES #148: an operator on 1.0.0.203 typed the command
the manual and the release notes both gave, and got

    PS /home/basti> Update-OS7
         | cannot take the update lock at /run/os7-update.lock: Exception
         | calling "Open" with "4" argument(s): "Access to the path
         | '/run/os7-update.lock' is denied."
    PS /home/basti> sudo Update-OS7
    sudo: 'Update-OS7': command not found

Nothing was wrong with the machine. `Update-OS7` needs root, said so in a .NET
method signature, and the obvious next move — `sudo <verb>` — cannot work at
all, because every verb in this product is a PowerShell FUNCTION and sudo
resolves executables. At the time there was **no privilege check anywhere in
powershell/OS7**: grep for `id -u`, `IsRoot`, `whoami`, `EUID`, `geteuid`,
"must run as root" and "requires root" returned nothing across the module. So
this was never one cmdlet's oversight, and a fix to one cmdlet is not a fix.

THE RULE. A function that is EXPORTED, carries a MUTATING verb, and TOUCHES
something only root can touch must call `Assert-OS7Elevated`. The baseline
below is what that came to when the rule was written; like check-layering.py's,
it **may fall and may not rise**, and every unguarded site is named on every
run so the next person can lower it rather than rediscover it.

HOW "TOUCHES SOMETHING ONLY ROOT CAN" IS DECIDED, and why not by the verb. 88
of the module's exported functions have a mutating verb and perhaps a quarter
of them need no privilege at all: the Active Directory surface acts on the
DIRECTORY over LDAPS with the operator's own admin credential, which is the
whole of AD-PLAN's stage 1 — "the machine is not a domain member and does not
need to be" — and `New-OS7KerberosTicket` is that operator's own ticket. A rule
keyed on the verb would flag twenty cmdlets that are right as they are, and a
rule that cries wolf is one somebody switches off. So the body is asked
instead, for three things the AST can see:

  * a string that is a path under /etc, /run, /boot, /usr, /var or /opt —
    including through a `$script:` variable, because that is how this module
    spells most of them (`$script:OS7AptSource` is '/etc/apt/sources.list.d/
    os7.sources', and a check that only read literals would have missed
    Set-OS7UpdateChannel, which is half of #148);
  * a string naming a privileged program — systemctl, apt-get, dpkg, zfs,
    useradd, adcli, cryptsetup, pam-auth-update and their neighbours — because
    those reach this module as ARGUMENTS to Invoke-OS7Native, not as commands;
  * a call to a write verb of one of the generic layers (New-ZfsDataset,
    Set-NetplanDocument, Enable-SystemdUnit …). Those are root operations by
    construction and carry no path of their own here, which is the point of
    the layering.

WHAT IT CANNOT SEE, said plainly: a privileged operation reached through a
helper defined in another file, and a path assembled at run time. Both would
read as unprivileged. This is a scan, not a proof — `run-surface.py --stage
write` typed at a machine is what finds the rest.

It needs `pwsh` and nothing else. OS7_SCAN_ROOT points it at a copy, which is
how the rule is proven to FIRE rather than merely to stay quiet.
"""
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# What the rule came to on the day it was written (2026-09-11), with
# Update-OS7, Set-OS7UpdateChannel and Restore-OS7 guarded — the three verbs
# #148 was reported against and the two an operator types next to it.
#
# IT MAY FALL AND MAY NOT RISE. A new mutating cmdlet either guards itself or
# moves this number in a diff somebody has to justify, which is the whole
# mechanism and the reason check-layering.py's baselines are written down
# rather than asserted at 0. Forty-two is DEBT, not a target: every one of
# them fails for an ordinary user today with whatever its first write
# happened to say, and every one is named on every run so the next person
# lowers the number instead of rediscovering the list.
#
# Restore-OS7 is guarded and is NOT in the 42, because the scan never saw it:
# all of its privileged work is delegated to Set-OS7BootEnvironment in another
# part of the module. That is this check's documented blind spot, met on the
# day it was written.
BASELINE = 42

SCAN = r'''
$ErrorActionPreference = 'Stop'
$root = $env:OS7_SCAN_ROOT
$mod  = Join-Path $root 'OS7'

# Read-only verbs. Everything else is treated as mutating.
$readVerbs = @('Get','Test','Measure','Read','Enter','Exit','Find','Show',
               'Convert','ConvertTo','ConvertFrom','Resolve','Select','Compare',
               'Format','Out','Write','Search')

# Programs only root can usefully run. They arrive as STRINGS here, because
# this module reaches native commands through Invoke-OS7Native -Command.
$privCmds = @('systemctl','systemd-cryptenroll','systemd-cryptsetup','apt','apt-get',
              'dpkg','dpkg-divert','dpkg-reconfigure','zfs','zpool','useradd','usermod',
              'groupadd','gpasswd','chpasswd','passwd','adcli','pam-auth-update',
              'faillock','grdctl','cryptsetup','update-initramfs','update-grub',
              'grub-install','mount','umount','chmod','chown','timedatectl',
              'hostnamectl','sysctl','dkms','ubuntu-drivers','netplan','nmcli',
              'resolvectl','chronyc','sssctl','realm','sanoid','syncoid','efibootmgr',
              'shutdown','reboot','mkinitramfs','zgenhostid','sshd','ssh-keygen')

# A write verb of one of the generic layers is a root operation by
# construction — EXCEPT the Directory layer's, and that exception is the whole
# reason this is a list rather than a wildcard. `Set-DirectoryEntry` writes to
# a DOMAIN CONTROLLER over LDAPS with the operator's own admin credential:
# AD-PLAN's stage 1, "the machine is not a domain member and does not need to
# be". Eighteen AD cmdlets flagged on the first run of this check and every one
# of them was right as it stood; a rule that cries wolf eighteen times is one
# somebody switches off.
$layerWrite = '^(New|Set|Remove|Enable|Disable|Start|Stop|Restart|Mount|Dismount|' +
              'Import|Export|Rename|Install|Uninstall|Register|Unregister|Add|Clear|' +
              'Reset|Suspend|Resume|Unlock|Move|Repair|Sync|Restore|Update|Join|Send|' +
              # NO `$`: these are PREFIXES. Anchoring the end matched only
              # bare nouns like New-Zpool and silently dropped New-ZfsDataset
              # and Set-SystemdUnitStartup — which took the whole
              # Compat.Windows service family out of the report.
              'Invoke)-(Zfs|Zpool|Systemd|Netplan|Net|Time)|' +
              # The realm half of the Directory layer IS local and privileged:
              # a join writes /etc/krb5.keytab and sssd.conf on THIS machine.
              # A ticket is the operator's own ccache and is not.
              '^(Join|Remove|Update)-DirectoryRealm$'

$sysPath = '^/(etc|run|boot|usr|var|opt)/'

function Get-Exported([string]$manifest) {
    if (-not (Test-Path $manifest)) { return @() }
    $d = Import-PowerShellDataFile -Path $manifest
    @($d.FunctionsToExport)
}
$exported = Get-Exported (Join-Path $mod 'OS7.psd1')
Write-Output ("EXPORTED`t{0}" -f $exported.Count)

$files = @(Get-ChildItem -Path $mod -Filter '*.ps1' -File) +
         @(Get-ChildItem -Path $mod -Filter '*.psm1' -File)

# PASS 1 — script-scope variables that hold a system path. This module spells
# most of its paths that way, and a scan that only read literals would miss
# them (Set-OS7UpdateChannel writes $script:OS7AptSource and nothing else).
$pathVars = @{}
foreach ($f in $files) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $f.FullName, [ref]$null, [ref]$null)
    foreach ($a in $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $left = $a.Left.Extent.Text
        if ($left -notmatch '^\$script:') { continue }
        $right = $a.Right.Extent.Text.Trim("'", '"', ' ')
        if ($right -match $sysPath) { $pathVars[$left.Substring(8)] = $right }
    }
}
Write-Output ("PATHVARS`t{0}" -f $pathVars.Count)

# PASS 2 — every function, classified.
foreach ($f in $files) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $f.FullName, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $name = $fn.Name
        if ($exported -notcontains $name) { continue }
        $verb = ($name -split '-')[0]
        if ($readVerbs -contains $verb) { continue }

        # A PATH ALONE IS NOT PRIVILEGE — reading /usr/lib/os7/release.json is
        # not writing it, and New-OS7BootEnvironmentName does exactly that to
        # compose a string. So a path counts only alongside a WRITE, while a
        # privileged program or a layer write verb counts on its own.
        $writeMarks = 'WriteAllText|AppendAllText|SetUnixFileMode|CreateDirectory|' +
                      'New-Item|Set-Content|Out-File|Remove-Item|' +
                      'Copy-Item|Move-Item|\[System\.IO\.File\]::Delete'
        $writes = $fn.Body.Extent.Text -match $writeMarks

        $why = @()
        $paths = @()
        $guarded = $false
        foreach ($c in $fn.Body.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cn = $c.GetCommandName()
            if ($cn -eq 'Assert-OS7Elevated') { $guarded = $true }
            if ($cn -and $cn -match $layerWrite) { $why += "layer:$cn" }
        }
        foreach ($s in $fn.Body.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
            $v = $s.Value
            if ($v -match $sysPath) { $paths += "path:$v" }
            # -ccontains: case SENSITIVE. `-Action 'Reboot'` is a parameter
            # value, not the program `reboot`, and reporting it as one makes
            # the reason column lie about a cmdlet that is flagged correctly
            # for another reason anyway.
            elseif ($privCmds -ccontains $v) { $why += "cmd:$v" }
        }
        foreach ($v in $fn.Body.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $vp = $v.VariablePath.UserPath
            if ($vp -like 'script:*' -and $pathVars.ContainsKey($vp.Substring(7))) {
                $paths += ("var:`$script:{0}" -f $vp.Substring(7))
            }
        }
        if ($writes) { $why += $paths }
        if ($why.Count -eq 0) { continue }

        $first = ($why | Select-Object -Unique | Select-Object -First 2) -join ', '
        Write-Output ("{0}`t{1}`t{2}`t{3}" -f
            $(if ($guarded) { 'GUARDED' } else { 'UNGUARDED' }),
            $name, $f.Name, $first)
    }
}
Write-Output ("FILES`t{0}" -f $files.Count)
'''


def find_pwsh():
    for name in ("pwsh", "pwsh.exe", "powershell.exe"):
        found = shutil.which(name)
        if found:
            return found
    return None


def main():
    print("\n### every mutating cmdlet refuses as a user, in a sentence (#148)")

    pwsh = find_pwsh()
    if not pwsh:
        print("      no pwsh on PATH; this check needs one and nothing else.")
        sys.exit(2)

    env = dict(os.environ)
    # Honoured if already set, for the same reason check-ps-traps.py honours it:
    # a scan that can only be pointed at a clean tree can be shown to report
    # nothing and never shown to report something.
    env["OS7_SCAN_ROOT"] = os.environ.get(
        "OS7_SCAN_ROOT", os.path.join(REPO, "powershell"))

    got = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", SCAN],
                         capture_output=True, encoding="utf-8", errors="replace",
                         env=env)
    if got.returncode != 0:
        print(got.stderr[-2000:], file=sys.stderr)
        sys.exit(1)

    guarded, unguarded = [], []
    exported = pathvars = files = 0
    for line in got.stdout.splitlines():
        p = line.rstrip().split("\t")
        if p[0] == "GUARDED":
            guarded.append(p[1:])
        elif p[0] == "UNGUARDED":
            unguarded.append(p[1:])
        elif p[0] == "EXPORTED":
            exported = int(p[1])
        elif p[0] == "PATHVARS":
            pathvars = int(p[1])
        elif p[0] == "FILES":
            files = int(p[1])

    print(f"      {files} file(s), {exported} exported function(s), "
          f"{pathvars} script-scope system path(s)")
    print(f"      {len(guarded) + len(unguarded)} mutating cmdlet(s) reach something "
          "only root can")
    print()

    if guarded:
        print("  GUARDED — they refuse as a user and say how to elevate")
        for name, where, why in guarded:
            print(f"      ok    {name:<34} {where}")
        print()

    if unguarded:
        print("  UNGUARDED — they fail as a user with whatever the write said")
        for name, where, why in unguarded:
            print(f"            {name:<34} {where:<28} {why[:60]}")
        print()

    n = len(unguarded)
    print(f"      {n} unguarded; baseline {BASELINE}")
    if n > BASELINE:
        print()
        print(f"{n - BASELINE} cmdlet(s) MORE than the baseline reach something only")
        print("root can touch without saying so. Call Assert-OS7Elevated -Cmdlet")
        print("<name> -Because '<what it does>' before the first write, or lower")
        print("the baseline in this file deliberately and say why.")
        sys.exit(1)
    if n < BASELINE:
        print()
        print(f"      BASELINE IS STALE: {n} < {BASELINE}. Lower it in this file —")
        print("      a baseline nobody tightens is a baseline that stops meaning")
        print("      anything (check-layering.py's argument, word for word).")
        sys.exit(1)

    print()
    print("The rule holds. Update-OS7, Set-OS7UpdateChannel and Restore-OS7 refuse")
    print("as a user and name the `sudo pwsh -c` form. The rest is debt: every one")
    print("of them is listed above, and this number stops it growing.")


if __name__ == "__main__":
    main()
