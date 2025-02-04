targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
// Flex Consumption functions are only supported in these regions.
// Run `az functionapp list-flexconsumption-locations --output table` to get the latest list
@allowed([
  'northeurope'
  'southeastasia'
  'eastasia'
  'eastus2'
  'southcentralus'
  'australiaeast'
  'eastus'
  'westus2'
  'uksouth'
  'eastus2euap'
  'westus3'
  'swedencentral'
])
param location string

param resourceGroupName string = ''
param webappName string = 'webapp'
param apiServiceName string = 'api'

@description('Location for the AI Services')
@allowed([
  'australiaeast'
  'canadaeast'
  'eastus'
  'eastus2'
  'francecentral'
  'japaneast'
  'northcentralus'
  'swedencentral'
  'switzerlandnorth'
  'uksouth'
  'westeurope'
])
@metadata({
  azd: {
    type: 'location'
  }
})
param aiServicesLocation string // Set in main.parameters.json
param modelName string = 'DeepSeek-R1'

// Location is not relevant here as it's only for the built-in api
// which is not used here. Static Web App is a global service otherwise
@description('Location for the Static Web App')
@allowed(['westus2', 'centralus', 'eastus2', 'westeurope', 'eastasia', 'eastasiastage'])
@metadata({
  azd: {
    type: 'location'
  }
})
param webappLocation string // Set in main.parameters.json

// Id of the user or app to assign application roles
param principalId string = ''

// Differentiates between automated and manual deployments
param isContinuousIntegration bool // Set in main.parameters.json

// ---------------------------------------------------------------------------
// Common variables

var abbrs = loadJsonContent('abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var principalType = isContinuousIntegration ? 'ServicePrincipal' : 'User'
var apiResourceName = '${abbrs.webSitesFunctions}api-${resourceToken}'
var storageAccountName = '${abbrs.storageStorageAccounts}${resourceToken}'
var aiServicesUrl = 'https://${aiServices.outputs.name}.openai.azure.com'

// ---------------------------------------------------------------------------
// Resources

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

module webapp 'br/public:avm/res/web/static-site:0.7.0' = {
  name: 'webapp'
  scope: resourceGroup
  params: {
    name: webappName
    location: webappLocation
    tags: union(tags, { 'azd-service-name': webappName })
    sku: 'Standard'
    linkedBackend: {
      resourceId: function.outputs.resourceId
      region: location
    }
  }
}

module function 'br/public:avm/res/web/site:0.13.0' = {
  name: 'api'
  scope: resourceGroup
  params: {
    tags: union(tags, { 'azd-service-name': apiServiceName })
    location: location
    kind: 'functionapp,linux'
    name: apiResourceName
    serverFarmResourceId: appServicePlan.outputs.resourceId
    appInsightResourceId: monitoring.outputs.applicationInsightsResourceId
    managedIdentities: { systemAssigned: true }
    appSettingsKeyValuePairs: {
      AZURE_AI_ENDPOINT: aiServicesUrl
      AZURE_AI_DEPLOYMENT_NAME: modelName
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'FtpsOnly'
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.outputs.primaryBlobEndpoint}${apiResourceName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 800
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'node'
        version: '20'
      }
    }
    storageAccountResourceId: storage.outputs.resourceId
    storageAccountUseIdentityAuthentication: true
    virtualNetworkSubnetId: vnet.outputs.subnetResourceIds[0]
  }
}

module appServicePlan 'br/public:avm/res/web/serverfarm:0.4.1' = {
  name: 'appserviceplan'
  scope: resourceGroup
  params: {
    name: '${abbrs.webServerFarms}${resourceToken}'
    tags: tags
    location: location
    skuName: 'FC1'
    reserved: true
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.15.0' = {
  name: 'storage'
  scope: resourceGroup
  params: {
    name: storageAccountName
    tags: tags
    location: location
    skuName: 'Standard_LRS'
    allowSharedKeyAccess: false
    // publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: vnet.outputs.subnetResourceIds[0]
          action: 'Allow'
        }
      ]
    }
    blobServices: {
      containers: [
        {
          name: apiResourceName
        }
      ]
    }
    roleAssignments: [
      {
        principalId: principalId
        principalType: principalType
        roleDefinitionIdOrName: 'Storage Blob Data Contributor'
      }
    ]
  }
}

module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.1' = {
  name: 'monitoring'
  scope: resourceGroup
  params: {
    tags: tags
    location: location
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
  }
}

module vnet 'br/public:avm/res/network/virtual-network:0.5.2' = {
  name: 'vnet'
  scope: resourceGroup
  params: {
    name: '${abbrs.networkVirtualNetworks}${resourceToken}'
    location: location
    tags: tags
    addressPrefixes: ['10.0.0.0/16']
    subnets: [
      {
        name: 'app'
        addressPrefix: '10.0.1.0/24'
        delegation: 'Microsoft.App/environments'
        serviceEndpoints: ['Microsoft.Storage']
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
    ]
  }
}

module aiServices 'br/public:avm/res/cognitive-services/account:0.9.2' = {
  name: 'aiServices'
  scope: resourceGroup
  params: {
    name: '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    location: aiServicesLocation
    tags: tags
    kind: 'AIServices'
    customSubDomainName: '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    publicNetworkAccess: 'Enabled'
    sku: 'S0'
    deployments: [
      {
        name: modelName
        model: {
          format: 'DeepSeek'
          name: modelName
          version: '1'
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 1
        }
      }
    ]
    disableLocalAuth: true
    roleAssignments: [
      {
        principalId: principalId
        principalType: principalType
        roleDefinitionIdOrName: 'Cognitive Services OpenAI User'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// System roles assignation

module aiServicesRoleApi 'br/public:avm/ptn/authorization/resource-role-assignment:0.1.2' = {
  scope: resourceGroup
  name: 'aiservices-role-api'
  params: {
    principalId: function.outputs.systemAssignedMIPrincipalId
    roleName: 'Cognitive Services OpenAI User'
    roleDefinitionId: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    resourceId: aiServices.outputs.resourceId
  }
}

module storageRoleApi 'br/public:avm/ptn/authorization/resource-role-assignment:0.1.2' = {
  scope: resourceGroup
  name: 'storage-role-api'
  params: {
    principalId: function.outputs.systemAssignedMIPrincipalId
    roleName: 'Storage Blob Data Contributor'
    roleDefinitionId: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
    resourceId: storage.outputs.resourceId
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = resourceGroup.name

output AZURE_AI_ENDPOINT string = aiServicesUrl
output AZURE_AI_DEPLOYMENT_NAME string = modelName

output WEBAPP_URL string = webapp.outputs.defaultHostname
