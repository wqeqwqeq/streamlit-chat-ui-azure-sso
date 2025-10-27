@allowed([
  'sbx'
  'dev'
  'qa'
  'prod'
])
param env string = 'sbx'
param resourcePrefix string
param appName string
param vehicleCatalogSourceServiceDomain string
param searchPersonalizationServiceDomain string
param searchPersonalizationServiceTests string
param location string = resourceGroup().location
param skuName string
param tokenProviderAppId string

// ======================== Internal ========================

var resourcePrefixShort = replace(resourcePrefix, '-', '')
var keyVaultName = '${resourcePrefixShort}kv'
var isSbx = contains(resourcePrefix, 'sbx')

var subscriptionId = subscription().subscriptionId
var resourceGroupName = resourceGroup().name

// name of the certificate in Azure Key Vault - specified when installing from venafi
var mtlsCertificateSecretName = 'mtlsCertificate'

// build path to cert on host from thumbprint
var mtlsCertificateThumbprint = certificate.properties.thumbprint

var mtlsCertificatePath = '/var/ssl/private/${mtlsCertificateThumbprint}.p12'

var logAnalyticsSubscriptionId = ((env == 'sbx' || env == 'dev' || env == 'qa')
  ? 'a7c3e077-ca40-46e4-9eaa-19b2ff694644'
  : '5c9243aa-2808-447a-8444-e77f4cc841d6')

// https://docs.microsoft.com/en-us/azure/templates/microsoft.managedidentity/userassignedidentities?t…
resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: '${resourcePrefix}-uai'
  location: location
}

// get reference to existing central Log Analytics workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' existing = {
  name: 'monitor-common-${env}-prime-logs'
  scope: resourceGroup(logAnalyticsSubscriptionId, 'kmx-${env}-east-monitor-common-prime')
}

// https://docs.microsoft.com/en-us/azure/templates/microsoft.insights/components?tabs=bicep
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${resourcePrefix}-insights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
  tags: {
    // needed for the portal to function properly
    'hidden-link:/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Web/sites/${resourcePrefix}-function-app': 'Resource'
  }
}

resource acrResource 'Microsoft.ContainerRegistry/registries@2021-06-01-preview' = {
  #disable-next-line BCP334
  name: '${resourcePrefixShort}cr'
  location: location
  sku: {
    name: 'basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

resource serverFarm 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: '${resourcePrefix}-plan'
  location: location
  sku: {
    name: skuName
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource appService 'Microsoft.Web/sites@2022-09-01' = {
  name: '${resourcePrefix}-app'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    keyVaultReferenceIdentity: userAssignedIdentity.id
    serverFarmId: serverFarm.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${resourcePrefixShort}cr.azurecr.io/${appName}:latest'
      alwaysOn: true
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: userAssignedIdentity.properties.clientId
        }
        {
          name: 'RESOURCE_GROUP_NAME'
          value: resourceGroup().name
        }
        {
          name: 'SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_USERNAME'
          value: acrResource.listCredentials().username
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
          value: acrResource.listCredentials().passwords[0].value
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://${acrResource.listCredentials().username}.azurecr.io'
        }
        {
          name: 'WEBSITES_PORT'
          value: '8501'
        }
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'KEY_VAULT_URI'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'VEHICLE_CATALOG_SOURCE_SERVICE_DOMAIN'
          value: vehicleCatalogSourceServiceDomain
        }
        {
          name: 'SEARCH_PERSONALIZATION_SERVICE_DOMAIN'
          value: searchPersonalizationServiceDomain
        }
        {
          name: 'SEARCH_PERSONALIZATION_SERVICE_TESTS'
          value: searchPersonalizationServiceTests
        }
        {
          name: 'SRC_PATH'
          value: '/opt/program/'
        }
        {
          // example of how you can load path to a private certificate to env variables
          name: 'MTLS_CERT_PATH'
          value: mtlsCertificatePath
        }
        {
          // loads private certificates to /var/ssl/private/
          name: 'WEBSITE_LOAD_CERTIFICATES'
          value: '*'
        }
      ]
      ipSecurityRestrictionsDefaultAction: isSbx ? 'Deny' : 'Allow'
      ipSecurityRestrictions: isSbx ? loadJsonContent('zscalerIPs.json') : []
    }
  }
}

resource appConfig 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'authsettingsV2'
  parent: appService
  properties: {
    platform: {
      enabled: !isSbx
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: !isSbx
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: !isSbx
        registration: {
          openIdIssuer: 'https://sts.windows.net/${subscription().tenantId}/v2.0'
          clientId: tokenProviderAppId
          clientSecretSettingName: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
        }
        login: {
          disableWWWAuthenticate: false
        }
        validation: {
          jwtClaimChecks: {}
          allowedAudiences: [
            'api://${tokenProviderAppId}'
          ]
          defaultAuthorizationPolicy: {
            allowedPrincipals: {}
          }
        }
      }
    }
    login: {
      routes: {}
      tokenStore: {
        enabled: !isSbx
        tokenRefreshExtensionHours: json('72.0')
        fileSystem: {}
        azureBlobStorage: {}
      }
      preserveUrlFragmentsForLogins: false
      cookieExpiration: {
        convention: 'FixedTime'
        timeToExpiration: '08:00:00'
      }
      nonce: {
        validateNonce: true
        nonceExpirationInterval: '00:05:00'
      }
    }
    httpSettings: {
      requireHttps: true
      routes: {
        apiPrefix: '/.auth'
      }
      forwardProxy: {
        convention: 'NoProxy'
      }
    }
  }
}

// https://docs.microsoft.com/en-us/azure/templates/microsoft.keyvault/vaults?tabs=bicep
resource keyVault 'Microsoft.KeyVault/vaults@2021-11-01-preview' = {
  name: keyVaultName
  location: location
  properties: {
    accessPolicies: [
      {
        objectId: userAssignedIdentity.properties.principalId
        permissions: {
          certificates: [
            'get'
          ]
          keys: [
            'get'
          ]
          secrets: [
            'get'
          ]
          storage: [
            'get'
          ]
        }
        tenantId: subscription().tenantId
      }
      {
        objectId: 'a46413b7-e168-4141-9561-38568e736a39' // KMX-AD-G-AZURE-DSML-Developers
        permissions: {
          certificates: [
            'all'
          ]
          keys: [
            'all'
          ]
          secrets: [
            'all'
          ]
          storage: [
            'all'
          ]
        }
        tenantId: subscription().tenantId
      }
      {
        objectId: '062bd80f-d2ce-46d7-bc2f-e42632529795' //Azure App Service (Used to pull certificates)
        permissions: {
          certificates: [
            'get'
          ]
          secrets: [
            'get'
          ]
        }
        tenantId: subscription().tenantId
      }
      {
        objectId: 'a1e8db30-78c1-48dc-b7ac-955ddbcbd76d' //Aperature Venafi Secret Install and Validate
        permissions: {
          certificates: [
            'get'
            'list'
            'create'
            'import'
          ]
          secrets: [
            'get'
          ]
        }
        tenantId: subscription().tenantId
      }
      {
        objectId: '59ae6d11-0d2c-4467-91be-3c0d292d56d9' //Azure Databricks (allows scopes to be created)
        permissions: {
          secrets: [
            'get'
            'list'
          ]
        }
        tenantId: subscription().tenantId
      }
    ]
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    enableRbacAuthorization: false
    enableSoftDelete: !isSbx
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
  }
}
// uploads clientmtls certificate from key vault to function app
// prerequisite: mtls certificate must be installed to kv from venafi
resource certificate 'Microsoft.Web/certificates@2022-09-01' = {
  name: 'mtlsCertificate'
  location: location
  properties: {
    keyVaultId: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.KeyVault/vaults/${keyVaultName}'
    keyVaultSecretName: mtlsCertificateSecretName
    serverFarmId: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.Web/serverfarms/${resourcePrefix}-plan'
  }
}
