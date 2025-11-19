param resourcePrefix string = 'stanley-dev-ui'
param location string = resourceGroup().location
param skuName string = 'b1'
param tokenProviderAppId string = '9ec6a2d4-9b95-4f01-b5d0-07eb4da70508'

@secure()
@description('PostgreSQL administrator login password')
param postgresAdminPassword string

param postgresAdminLogin string = 'pgadmin'
param postgresSku string = 'Standard_B1ms'
param postgresStorageSizeGB int = 32
param postgresDatabaseName string = 'chat_history'

@description('Redis Cache SKU name')
@allowed(['Basic', 'Standard', 'Premium'])
param redisSkuName string = 'Basic'

@description('Redis Cache capacity (0=250MB, 1=1GB, 2=2.5GB)')
param redisSkuCapacity int = 0

@description('VNet address space (CIDR notation, e.g., 10.0.0.0/16)')
param vnetAddressSpace string

@description('App Service subnet address prefix (CIDR notation, e.g., 10.0.1.0/26)')
param subnetAddressPrefix string

// ======================== Internal ========================

var resourcePrefixShort = replace(resourcePrefix, '-', '')
var keyVaultName = '${resourcePrefixShort}kv4'
var postgresServerName = '${resourcePrefix}-postgres'



// https://docs.microsoft.com/en-us/azure/templates/microsoft.managedidentity/userassignedidentities?t…
resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: '${resourcePrefix}-uai'
  location: location
}

// Azure Container Registry for storing Docker images
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: '${resourcePrefixShort}acr'  // e.g., stanleydevuiacr (no hyphens)
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false  // Use managed identity instead of admin credentials
  }
}

// Grant the user-assigned managed identity AcrPull role on the container registry
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, userAssignedIdentity.id, 'acrpull')
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')  // AcrPull role
    principalId: userAssignedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// get reference to existing central Log Analytics workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: 'test-log-ws'
  location: location

  properties: {
    retentionInDays: 30
    features: {
      immediatePurgeDataOn30Days: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    sku: {
    name: 'PerGB2018'
  }
  }
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

// ======================== Networking ========================

// Public IP for NAT Gateway (must be Standard SKU with Static allocation)
resource natPublicIP 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${resourcePrefix}-nat-pip'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

// NAT Gateway for static outbound IP
resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = {
  name: '${resourcePrefix}-nat-gateway'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIP.id
      }
    ]
  }
}

// Virtual Network with App Service integration subnet
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${resourcePrefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    subnets: [
      {
        name: 'appServiceSubnet'
        properties: {
          addressPrefix: subnetAddressPrefix
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          natGateway: {
            id: natGateway.id
          }
        }
      }
    ]
  }
}

resource appService 'Microsoft.Web/sites@2022-09-01' = {
  name: '${resourcePrefix}-app'
  location: location
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    keyVaultReferenceIdentity: userAssignedIdentity.id
    serverFarmId: serverFarm.id
    virtualNetworkSubnetId: virtualNetwork.properties.subnets[0].id

    siteConfig: {
      // CHANGE: Use Docker container instead of Python runtime
      linuxFxVersion: 'DOCKER|${containerRegistry.properties.loginServer}/${resourcePrefix}-app:latest'
      alwaysOn: true
      // Configure ACR authentication using managed identity
      acrUseManagedIdentityCreds: true  // FIXED: Was false, should be true
      acrUserManagedIdentityID: userAssignedIdentity.properties.clientId
      // Route all outbound traffic through VNet
      vnetRouteAllEnabled: true

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
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'KEY_VAULT_URI'
          value: keyVault.properties.vaultUri
        }
        {
          // loads private certificates to /var/ssl/private/
          name: 'WEBSITE_LOAD_CERTIFICATES'
          value: '*'
        }
        // ACR configuration
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://${containerRegistry.properties.loginServer}'
        }
        // Critical: Tell Azure the container listens on port 8000
        {
          name: 'WEBSITES_PORT'
          value: '8000'
        }
      ]
      ipSecurityRestrictionsDefaultAction: 'Allow'
    }
  }
  dependsOn: [
    acrPullRoleAssignment  // Ensure RBAC is configured before app starts
  ]
}

resource appConfig 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'authsettingsV2'
  parent: appService
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
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
        enabled: true
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
    accessPolicies: []
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    enableRbacAuthorization: false
    enableSoftDelete: true
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

// Grant Key Vault access to App Service managed identity
resource keyVaultAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2021-11-01-preview' = {
  name: 'add'
  parent: keyVault
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: userAssignedIdentity.properties.principalId
        permissions: {
          secrets: [
            'get'
            'list'
          ]
        }
      }
    ]
  }
}

// ======================== PostgreSQL Flexible Server ========================
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-03-01-preview' = {
  name: postgresServerName
  location: location
  sku: {
    name: postgresSku
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    version: '15'
    storage: {
      storageSizeGB: postgresStorageSizeGB
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

// PostgreSQL database
resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-03-01-preview' = {
  name: postgresDatabaseName
  parent: postgresServer
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Firewall rule to allow traffic from NAT Gateway only
resource postgresFirewallRule 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-03-01-preview' = {
  name: 'AllowNATGateway'
  parent: postgresServer
  properties: {
    startIpAddress: natPublicIP.properties.ipAddress
    endIpAddress: natPublicIP.properties.ipAddress
  }
}

// Store PostgreSQL connection string in Key Vault
resource postgresConnectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  name: 'postgres-connection-string'
  parent: keyVault
  properties: {
    value: 'postgresql://${postgresAdminLogin}:${postgresAdminPassword}@${postgresServer.properties.fullyQualifiedDomainName}:5432/${postgresDatabaseName}?sslmode=require'
  }
  dependsOn: [
    keyVaultAccessPolicy
  ]
}

// ======================== Azure Redis Cache ========================
resource redisCache 'Microsoft.Cache/redis@2023-08-01' = {
  name: '${resourcePrefix}-redis'
  location: location
  properties: {
    sku: {
      name: redisSkuName
      family: 'C'
      capacity: redisSkuCapacity
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    redisConfiguration: {
      'maxmemory-policy': 'allkeys-lru'  // Evict least recently used
    }
  }
}

// ======================== Outputs ========================
output redisHostName string = redisCache.properties.hostName
output redisSslPort int = redisCache.properties.sslPort
output postgresHostName string = postgresServer.properties.fullyQualifiedDomainName
output acrLoginServer string = containerRegistry.properties.loginServer
output acrName string = containerRegistry.name
output natGatewayPublicIP string = natPublicIP.properties.ipAddress
output vnetId string = virtualNetwork.id
output appServiceSubnetId string = virtualNetwork.properties.subnets[0].id
