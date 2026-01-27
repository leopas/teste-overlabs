// Template Bicep para infraestrutura completa na Azure
// Uso: az deployment group create --resource-group <rg> --template-file azure/bicep/main.bicep --parameters @azure/bicep/parameters.json

@description('Nome do projeto')
param projectName string = 'rag-overlabs'

@description('Localização dos recursos')
param location string = resourceGroup().location

@description('SKU do Container Registry')
param acrSku string = 'Basic'

@description('Tier do MySQL')
param mysqlTier string = 'Burstable'

@description('SKU do MySQL')
param mysqlSkuName string = 'Standard_B1ms'

@description('Admin user do MySQL')
@secure()
param mysqlAdminUser string = 'ragadmin'

@description('Admin password do MySQL')
@secure()
param mysqlAdminPassword string

@description('SKU do Redis')
param redisSku string = 'Basic'

@description('Tamanho do Redis')
param redisVmSize string = 'c0'

// Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: '${projectName}acr'
  location: location
  sku: {
    name: acrSku
  }
  properties: {
    adminUserEnabled: true
  }
}

// Redis Cache
resource redis 'Microsoft.Cache/redis@2023-08-01' = {
  name: '${projectName}-redis'
  location: location
  properties: {
    sku: {
      name: redisSku
      family: 'C'
      capacity: redisVmSize == 'c0' ? 0 : 1
    }
    minimumTlsVersion: '1.2'
  }
}

// MySQL Flexible Server
resource mysqlServer 'Microsoft.DBforMySQL/flexibleServers@2023-06-30' = {
  name: '${projectName}-mysql'
  location: location
  sku: {
    name: mysqlSkuName
    tier: mysqlTier
  }
  properties: {
    administratorLogin: mysqlAdminUser
    administratorLoginPassword: mysqlAdminPassword
    version: '8.0.21'
    storage: {
      storageSizeGB: 32
    }
    publicNetworkAccess: 'Enabled'
  }
}

// MySQL Database
resource mysqlDatabase 'Microsoft.DBforMySQL/flexibleServers/databases@2023-06-30' = {
  parent: mysqlServer
  name: 'rag_audit'
}

// Container Apps Environment
resource containerEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: '${projectName}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
    }
  }
}

// Qdrant Container App
resource qdrantApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${projectName}-qdrant'
  location: location
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 6333
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          image: 'qdrant/qdrant:latest'
          name: 'qdrant'
          env: [
            {
              name: 'QDRANT__SERVICE__GRPC_PORT'
              value: '6334'
            }
          ]
          resources: {
            cpu: json('1.0')
            memory: '2.0Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// API Container App
resource apiApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${projectName}-app'
  location: location
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'http'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: ''
        }
      ]
    }
    template: {
      containers: [
        {
          image: '${acr.properties.loginServer}/rag-api:latest'
          name: 'api'
          env: [
            {
              name: 'QDRANT_URL'
              value: 'http://${qdrantApp.properties.configuration.ingress.fqdn}:6333'
            }
            {
              name: 'REDIS_URL'
              value: 'rediss://:${redis.listKeys().primaryKey}@${redis.properties.hostName}:${redis.properties.port}/0'
            }
            {
              name: 'MYSQL_HOST'
              value: mysqlServer.properties.fullyQualifiedDomainName
            }
            {
              name: 'MYSQL_PORT'
              value: '3306'
            }
            {
              name: 'MYSQL_USER'
              value: mysqlAdminUser
            }
            {
              name: 'MYSQL_PASSWORD'
              value: mysqlAdminPassword
            }
            {
              name: 'MYSQL_DATABASE'
              value: 'rag_audit'
            }
            {
              name: 'TRACE_SINK'
              value: 'mysql'
            }
            {
              name: 'AUDIT_LOG_ENABLED'
              value: '1'
            }
            {
              name: 'AUDIT_LOG_INCLUDE_TEXT'
              value: '1'
            }
            {
              name: 'AUDIT_LOG_RAW_MODE'
              value: 'risk_only'
            }
            {
              name: 'ABUSE_CLASSIFIER_ENABLED'
              value: '1'
            }
            {
              name: 'PROMPT_FIREWALL_ENABLED'
              value: '0'
            }
            {
              name: 'LOG_LEVEL'
              value: 'INFO'
            }
          ]
          resources: {
            cpu: json('2.0')
            memory: '4.0Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 5
      }
    }
  }
}

// Outputs
output acrLoginServer string = acr.properties.loginServer
output apiUrl string = 'https://${apiApp.properties.configuration.ingress.fqdn}'
output qdrantUrl string = 'http://${qdrantApp.properties.configuration.ingress.fqdn}:6333'
output mysqlFqdn string = mysqlServer.properties.fullyQualifiedDomainName
output redisHost string = redis.properties.hostName
output redisPort string = string(redis.properties.port)
