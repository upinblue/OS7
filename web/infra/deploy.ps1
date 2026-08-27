<#
.SYNOPSIS
	Create everything os7.org needs in Azure, and print what has to be done by hand afterwards.

.DESCRIPTION
	Wraps main.bicep. Run it once. Everything it creates is idempotent, so running
	it again after editing the template updates in place rather than duplicating.

	It deliberately does NOT bind the custom domain and does NOT upload any ISO.
	The domain cannot be bound until the registrar points os7.org at the name
	servers this prints, and uploading is a decision rather than a step - the
	images are the only part of this site that costs real money to serve.

.EXAMPLE
	./deploy.ps1 -ResourceGroup rg-os7-web -StorageAccountName os7dl -BudgetEmail bastian.wirth@upinblue.com
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory)][string] $ResourceGroup,

	# Ends up in every published download URL and, later, in the apt source of
	# every installed machine. Choose it once.
	[Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,24}$')][string] $StorageAccountName,

	[Parameter(Mandatory)][string] $BudgetEmail,

	[string] $Location = 'westeurope',
	[string] $SiteName = 'os7-site',
	[string] $Domain   = 'os7.org',
	[int]    $Budget   = 25,
	[switch] $NoDnsZone
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
	throw 'The Azure CLI is not on PATH. Install it, then run az login.'
}

Write-Host '==> subscription' -ForegroundColor Cyan
az account show --query '{name:name, id:id, tenant:tenantId}' -o table

# The object ID of whoever is signed in, so the template can grant them upload
# rights. Shared-key access is disabled on the account, so without this the
# first upload fails with an authorization error rather than a missing key.
$principalId = az ad signed-in-user show --query id -o tsv
Write-Host "==> uploads will be granted to object id $principalId"

Write-Host "==> resource group $ResourceGroup in $Location" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none

Write-Host '==> deploying' -ForegroundColor Cyan
$result = az deployment group create `
	--resource-group $ResourceGroup `
	--template-file (Join-Path $here 'main.bicep') `
	--parameters `
		storageAccountName=$StorageAccountName `
		siteName=$SiteName `
		location=$Location `
		domainName=$Domain `
		createDnsZone=$(if ($NoDnsZone) { 'false' } else { 'true' }) `
		monthlyBudget=$Budget `
		budgetContactEmail=$BudgetEmail `
		uploaderPrincipalId=$principalId `
	--query properties.outputs -o json | ConvertFrom-Json

$hostname    = $result.siteDefaultHostname.value
$storageBase = $result.storageBase.value
$nameServers = $result.nameServers.value

Write-Host ''
Write-Host '=== created ===' -ForegroundColor Green
Write-Host "site           https://$hostname"
Write-Host "iso container  $storageBase"
Write-Host "repo container $($result.repoBase.value)"

Write-Host ''
Write-Host '=== 1. wire up deployment from GitHub ===' -ForegroundColor Yellow
Write-Host 'Take the deployment token and put it in the repository as the secret'
Write-Host 'AZURE_STATIC_WEB_APPS_API_TOKEN. The workflow in .github/workflows/deploy-web.yml'
Write-Host 'uses it and nothing else - no service principal, no subscription access.'
Write-Host ''
Write-Host "  az staticwebapp secrets list --name $SiteName --resource-group $ResourceGroup --query properties.apiKey -o tsv"
Write-Host "  gh secret set AZURE_STATIC_WEB_APPS_API_TOKEN --repo upinblue/OS7"

if (-not $NoDnsZone) {
	Write-Host ''
	Write-Host '=== 2. point the domain at Azure DNS ===' -ForegroundColor Yellow
	Write-Host "At the registrar for $Domain, replace the name servers with these four."
	Write-Host 'Nothing else in this list works until that has propagated:'
	foreach ($ns in $nameServers) { Write-Host "  $ns" }
	Write-Host ''
	Write-Host '=== 3. bind the domain ===' -ForegroundColor Yellow
	Write-Host "Portal > $SiteName > Custom domains > Add > 'Custom domain on Azure DNS',"
	Write-Host "pick the $Domain zone. That writes the ALIAS and TXT records itself and"
	Write-Host 'issues the certificate. Add www as a second custom domain the same way.'
	Write-Host 'Apex domain changes can take up to 72 hours to propagate.'
}

Write-Host ''
Write-Host '=== 4. when there is an ISO to publish ===' -ForegroundColor Yellow
Write-Host "  python web/tools/publish-release.py out/OS7-<version>-amd64.iso out/OS7-<version>-arm64.iso ``"
Write-Host "      --storage-base $storageBase --print-upload"
Write-Host 'Run the az commands it prints, then commit and push the four files it wrote.'
Write-Host ''
Write-Host 'A budget alert is set at' $Budget 'EUR/month to' $BudgetEmail '. It alerts; it does not'
Write-Host 'stop anything. The kill switch is:'
Write-Host "  az storage container set-permission --name iso --account-name $StorageAccountName --public-access off --auth-mode login"
