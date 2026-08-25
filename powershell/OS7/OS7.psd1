# =============================================================================
# OS/7 PowerShell module manifest
#
#   *** STUB — no logic behind any of this ***
# =============================================================================
@{
	RootModule        = 'OS7.psm1'
	ModuleVersion     = '0.1.0'
	GUID              = 'aa3b48e6-1eda-49ca-b4e6-0267ae494fb4'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'OS/7 system management: curated release train over ZFS boot environments. Storage (New-OS7Storage) is implemented and runs on the Zfs module rather than on zfs/zpool directly; Set-OS7Mode/Update-OS7/Restore-OS7 are still stubs.'

	PowerShellVersion = '7.0'

	FunctionsToExport = @(
		# Implemented — the ZFS layer os7-setup and Update-OS7 share (SETUP-PLAN §6.3)
		'New-OS7Storage', 'New-OS7BootEnvironmentName',
		# Implemented — the classic desktop, amd64 GUI mode
		'Get-OS7Theme', 'Set-OS7Theme',
		# Stubs — the command surface README.md documents
		'Set-OS7Mode', 'Update-OS7', 'Restore-OS7')
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags       = @('OS7', 'Ubuntu', 'ZFS', 'Entra', 'Intune', 'Azure-Arc')
			LicenseUri = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri = 'https://github.com/upinblue/os7'
		}
	}
}
