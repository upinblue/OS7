# =============================================================================
# OS/7 PowerShell module manifest
#
#   *** STUB — no logic behind any of this ***
# =============================================================================
@{
	RootModule        = 'OS7.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = 'aa3b48e6-1eda-49ca-b4e6-0267ae494fb4'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'OS/7 system management: curated release train over ZFS boot environments. STUB — function signatures only, no implementation.'

	PowerShellVersion = '7.0'

	FunctionsToExport = @('Set-OS7Mode', 'Update-OS7', 'Restore-OS7')
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
