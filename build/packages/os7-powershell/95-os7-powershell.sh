# OS/7: hand interactive human sessions over to PowerShell 7.
#
# Every guard here exists to avoid breaking something specific. Removing any of
# them will break that thing.

# 0. BEFORE THE GUARDS: PowerShell does not look for its own updates. It is
#    updated by Update-OS7 with everything else (docs/DECISIONS.md, "Shell"),
#    and left alone it calls Microsoft at the first start of every day and, when
#    it finds a release, tells the user to install it some other way. Measured
#    on a fresh 1.0.0.245 desktop: the first login wrote
#    ~/.cache/powershell/7.6.5/update1_v7.6.9_2026-10-25. Exported for every
#    login shell, so a `pwsh` started from bash and the hand-off below both
#    inherit it; /usr/lib/environment.d/60-os7-powershell.conf
#    is the same for what the desktop session starts. SESSION-QOL-SURVEY Q12.
#    And no telemetry either (CURATION-AND-DELIVERY-PLAN C17, owner's decision
#    2026-10-29): a fresh login left ~/.cache/powershell/telemetry.uuid behind,
#    and a managed fleet reports to whoever manages it.
POWERSHELL_UPDATECHECK=Off
POWERSHELL_TELEMETRY_OPTOUT=1
export POWERSHELL_UPDATECHECK POWERSHELL_TELEMETRY_OPTOUT

# 1. Interactive shells only. Without this, scp/sftp, `ssh host command`, cron
#    and dpkg hooks would all get exec'd into pwsh and break.
case $- in
	*i*) ;;
	*) return ;;
esac

# 2. A non-interactive ssh command still sets this; belt and braces with (1).
[ -n "${SSH_ORIGINAL_COMMAND:-}" ] && return

# 3. Re-entry guard. pwsh itself can start a login bash; without this the two
#    would exec each other forever.
[ -n "${OS7_PWSH_ACTIVE:-}" ] && return

# 4. Never strand a user without a shell if PowerShell is missing or broken.
[ -x /usr/bin/pwsh ] || return

# 5. Opt-out, so an admin can get plain bash without editing system files.
[ -n "${OS7_NO_PWSH:-}" ] && return

OS7_PWSH_ACTIVE=1
export OS7_PWSH_ACTIVE
exec /usr/bin/pwsh -NoLogo
