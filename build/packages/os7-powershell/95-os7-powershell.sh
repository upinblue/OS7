# OS/7: hand interactive human sessions over to PowerShell 7.
#
# Every guard here exists to avoid breaking something specific. Removing any of
# them will break that thing.

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
