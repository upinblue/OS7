// =============================================================================
// OS/7 — everything os7.org needs in Azure, in one deployment.
//
//   az deployment group create -g <rg> -f main.bicep -p storageAccountName=<name>
//
// Three resources, and the reason each one is the cheap option:
//
//   Static Web App (Free)   the site. $0, 100 GB/month included, free managed
//                           certificates, apex domain supported through an
//                           Azure DNS zone. There is NO overage on Free: past
//                           100 GB the site is cut off rather than billed, so
//                           the bill cannot run away here.
//
//   Storage account         the ISOs, and later the OS/7 apt repository. This
//                           is the part that costs money, and it is EGRESS, not
//                           storage: about 0.20 USD/month to hold four images,
//                           against 0.087 USD/GB once the 100 GB of free
//                           monthly egress is used up. One amd64 ISO is 3.1 GiB
//                           - roughly 30 downloads a month are free, and every
//                           one after that is about 0.29 USD. See the budget
//                           below, which exists because blob storage has no
//                           bandwidth cap of its own.
//
//   DNS zone (optional)     needed for the APEX domain os7.org: Static Web Apps
//                           validates and binds a root domain through ALIAS and
//                           TXT records in an Azure DNS zone. A www-only site
//                           would not need this.
//
// WHAT THIS DOES NOT CREATE, on purpose:
//   - Azure Front Door. It is the only way to get HTTPS on a custom domain in
//     front of blob storage (root domains are not supported at all, and HTTPS
//     on a storage custom domain requires Front Door or CDN). At a ~30+ USD
//     monthly base fee that is more than the bandwidth it would be fronting.
//     The download links go to os7.org and are 302-redirected to the blob URL
//     instead - see staticwebapp.config.json.
//   - the custom domain binding. It cannot be made until the registrar points
//     os7.org at the name servers this deployment outputs.
// =============================================================================

@description('Region for the storage account. Any European region is the same egress price band.')
param location string = 'westeurope'

@description('Region for the Static Web App. Static Web Apps is offered in only a few regions; westeurope is the European one. If it is rejected, list the valid ones with: az provider show -n Microsoft.Web --query "resourceTypes[?resourceType==\'staticSites\'].locations"')
param staticSiteLocation string = 'westeurope'

@description('Globally unique storage account name, 3-24 lowercase letters and digits. This name ends up inside every published download URL and, later, in the apt source of every installed machine - it is not easy to change afterwards.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Name of the Static Web App resource.')
param siteName string = 'os7-site'

@description('Create a public DNS zone for the domain. Required for the apex domain.')
param createDnsZone bool = true

@description('The domain. Only used when createDnsZone is true.')
param domainName string = 'os7.org'

@description('Monthly budget in EUR that raises an alert. Blob storage has no bandwidth limit, so this alert is the only brake on a download bill.')
param monthlyBudget int = 25

@description('Address the budget alert is mailed to.')
param budgetContactEmail string

@description('Object ID of the account that will upload the ISOs. Shared-key access is disabled on the storage account, so uploading needs the Storage Blob Data Contributor role rather than an account key. Get it with: az ad signed-in-user show --query id -o tsv. Leave empty to assign the role by hand later.')
param uploaderPrincipalId string = ''

// --- the site --------------------------------------------------------------

resource site 'Microsoft.Web/staticSites@2023-01-01' = {
  name: siteName
  location: staticSiteLocation
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    // No repositoryUrl here. Linking GitHub from a template needs a PAT in the
    // deployment; the workflow authenticates with the deployment token instead,
    // which is fetched after this runs and put in a GitHub secret.
    allowConfigFileUpdates: true
    stagingEnvironmentPolicy: 'Enabled'
  }
}

// --- the downloads ---------------------------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    // LRS. These files are reproducible from the repository and a pinned
    // archive; paying for geo-redundancy to protect a build artefact would be
    // paying twice for the same property.
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: false

    // Anonymous access is off by default on new accounts and has to be turned
    // on deliberately. It is on here because these files are meant to be
    // downloadable by anyone without a token - and because turning the CONTAINER
    // back to private is the kill switch if the egress bill ever runs.
    //
    // If tenant policy forbids this, the fallback is the static website ($web)
    // container, which stays publicly readable regardless of this flag.
    allowBlobPublicAccess: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

// 'Blob' rather than 'Container': anonymous clients may read a file whose name
// they know, and may NOT list the container. Nothing here is secret, but an
// enumerable container publishes every unreleased build the moment it is staged.
resource isoContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'iso'
  properties: {
    publicAccess: 'Blob'
  }
}

// The signed OS/7 package suite and the release index (build/lib/build-os7-repo.sh)
// are a static tree too, and they belong on the same account. Created empty.
resource repoContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'repo'
  properties: {
    publicAccess: 'Blob'
  }
}

// Storage Blob Data Contributor for whoever uploads. Named by its well-known
// GUID because the role name is not resolvable from a template.
var blobDataContributor = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource uploaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(uploaderPrincipalId)) {
  scope: storage
  name: guid(storage.id, uploaderPrincipalId, blobDataContributor)
  properties: {
    roleDefinitionId: blobDataContributor
    principalId: uploaderPrincipalId
    principalType: 'User'
  }
}

// --- the brake -------------------------------------------------------------

resource budget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: '${siteName}-monthly'
  properties: {
    category: 'Cost'
    amount: monthlyBudget
    timeGrain: 'Monthly'
    timePeriod: {
      // A budget needs a start date. Azure requires the first of a month; this
      // is a fixed date rather than utcNow() so that redeploying does not move
      // the budget period and reset what has been counted.
      startDate: '2026-09-01T00:00:00Z'
      endDate: '2036-09-01T00:00:00Z'
    }
    notifications: {
      halfway: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 50
        contactEmails: [budgetContactEmail]
        thresholdType: 'Actual'
      }
      reached: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 90
        contactEmails: [budgetContactEmail]
        thresholdType: 'Actual'
      }
      forecast: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        contactEmails: [budgetContactEmail]
        thresholdType: 'Forecasted'
      }
    }
  }
}

// --- DNS -------------------------------------------------------------------

resource dns 'Microsoft.Network/dnsZones@2023-07-01-preview' = if (createDnsZone) {
  name: domainName
  location: 'global'
}

// --- what the next steps need ----------------------------------------------

output siteDefaultHostname string = site.properties.defaultHostname
output storageBase string = '${storage.properties.primaryEndpoints.blob}iso'
output repoBase string = '${storage.properties.primaryEndpoints.blob}repo'
output nameServers array = createDnsZone ? dns!.properties.nameServers : []
