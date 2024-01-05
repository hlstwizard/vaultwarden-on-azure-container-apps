@description('The Azure region to install it')
param location string = 'eastasia'

@description('Base name for all resources')
param baseName string

@description('The password to access the /admin page of the Vaultwarden installation')
@secure()
param adminToken string

@description('Enable VNet integration. NOTE: This will create additional components which produces additional costs.')
param enableVnetIntegrationWithAdditionalCosts bool = true

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = if (enableVnetIntegrationWithAdditionalCosts) {
  name: 'vnet${baseName}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/23'
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [
                location
              ]
            }
          ]
        }
      }
    ]
  }
}

resource logworkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  #disable-next-line BCP334
  name: 'law${baseName}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    workspaceCapping: {
      dailyQuotaGb: 1
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'stgvaultwarden${baseName}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: true
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
    networkAcls: {
      defaultAction: enableVnetIntegrationWithAdditionalCosts ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
      virtualNetworkRules: enableVnetIntegrationWithAdditionalCosts ? [
        {
          id: '${vnet.id}/subnets/default'
          action: 'Allow'
        }
      ] : null
    }
  }
}

resource fileservices 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  name: 'default'
  parent: storage
}

resource fileshare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: 'vaultwarden'
  parent: fileservices
  properties: {
    enabledProtocols: 'SMB'
    shareQuota: 1024
  }
}

resource managedEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: 'managedenv-${baseName}-vaultwarden'
  location: location
  properties: {
    vnetConfiguration: {
      internal: false
      infrastructureSubnetId: enableVnetIntegrationWithAdditionalCosts ? vnet.properties.subnets[0].id : null
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logworkspace.properties.customerId
        sharedKey: logworkspace.listKeys().primarySharedKey
      }
    }
  }
}

resource managedEnvStorage 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
  name: fileshare.name
  parent: managedEnv
  properties: {
    azureFile: {
      accessMode: 'ReadWrite'
      shareName: fileshare.name
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
    }
  }
}

resource vaultwardenapp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'vaultwarden${baseName}'
  location: location
  properties: {
    environmentId: managedEnv.id
    configuration: {
      secrets: [
        {
          name: 'fileshare-connectionstring'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
        }
        {
          name: 'admintoken'
          value: adminToken
        }
      ]
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        allowInsecure: false
        targetPort: 80
        transport: 'auto'
        traffic: [
          {
            weight: 100
            latestRevision: true
          }
        ]
      }
    }
    template: {
      containers: [
        {
          image: 'docker.io/vaultwarden/server:latest'
          name: 'vaultwarden'
          resources: {
            #disable-next-line BCP036
            cpu: '0.25'
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'AZURE_STORAGEFILE_CONNECTIONSTRING'
              secretRef: 'fileshare-connectionstring'
            }
            {
              name: 'SIGNUPS_ALLOWED'
              value: 'false'
            }
            {
              name: 'ADMIN_TOKEN'
              secretRef: 'admintoken'
            }
            {
              name: 'ENABLE_DB_WAL'
              value: 'true'
            }
            {
              name: 'SHOW_PASSWORD_HINT'
              value: 'false'
            }
          ]
          volumeMounts: [
            {
              volumeName: fileshare.name
              mountPath: '/data'
            }
          ]
        }
      ]
      volumes: [
        {
          name: fileshare.name
          storageName: managedEnvStorage.name
          storageType: 'AzureFile'
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}
