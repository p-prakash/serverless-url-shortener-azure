@description('Name of the API environment')
param Environ string

@description('Primary Azure region to be used')
param location string

@description('Azure AD B2C Tenant Name')
param aadB2cOrg string

@description('Azure AD B2C User Flow Name for Sign Up and Sign In')
param aadB2cUserFlow string

@description('Azure AD B2C App Client ID')
param aadB2cApiClientId string

@description('URL for shortening domain')
param shortUrl string

@description('DNS Zone for shortening domain')
param dnsZone string

@description('Resource Group of the DNS Zone')
param dnsZoneRG string

@description('GitHub URL of the static web apps repository')
param repoURL string

@description('GitHub access Token')
@secure()
param repoToken string

@description('Suffix to add to the resources')
param suffix string

@description('Name of the resource tag.')
param tagName object = {
  Purpose: 'url-shortener'
  Environment: Environ
}

var databaseName = 'us-db-${toLower(suffix)}'
var containerName = 'us-container-${toLower(suffix)}'

// Create CosmosDB Account
resource dbAccount 'Microsoft.DocumentDB/databaseAccounts@2022-08-15' = {
  name: 'us-dba-${toLower(suffix)}'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        isZoneRedundant: true
      }
    ]
    databaseAccountOfferType: 'Standard'
    backupPolicy: {
      type: 'Continuous'
    }
    enableAutomaticFailover: true
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }
  tags: tagName
}

// Create CosmosDB Database
resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2022-08-15' = {
  name: databaseName
  parent: dbAccount
  properties: {
    resource: {
      id: databaseName
    }
  }
}

// Create CosmosDB Container
resource dbContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2022-08-15' = {
  name: containerName
  parent: database
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [
          '/id'
        ]
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/_etag/?'
          }
        ]
      }
    }
  }
}

// Create Storage Account for Function App
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  name: 'usstore${toLower(suffix)}'
  location: location
  tags: tagName
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// Create Static Web Apps for hosting the Website
resource URLShortenerWebsite 'Microsoft.Web/staticSites@2022-03-01' = {
  name: 'us-swa-${toLower(suffix)}'
  location: location
  tags: tagName
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    allowConfigFileUpdates: true
    branch: 'main'
    enterpriseGradeCdnStatus: 'Disabled'
    provider: 'GitHub'
    repositoryToken: repoToken
    repositoryUrl: repoURL
    stagingEnvironmentPolicy: 'Disabled'
  }
}

// Create Front Door CDN Profile
resource URLShortenerCdnProfile 'Microsoft.Cdn/profiles@2022-05-01-preview' = {
  name: 'us-cdn-${toLower(suffix)}'
  location: 'global'
  tags: tagName
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  properties: {
    extendedProperties: {}
    originResponseTimeoutSeconds: 60
  }
}

// Create Front Door CDN Endpoint
resource URLShortenerCdnEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2022-05-01-preview' = {
  name: 'us-cdn-ep-${toLower(suffix)}'
  location: 'global'
  tags: tagName
  parent: URLShortenerCdnProfile
  properties: {
    enabledState: 'Enabled'
  }
}

// Create Front Door Web Origin Group
resource URLShortenerWebOriginGroup 'Microsoft.Cdn/profiles/originGroups@2022-05-01-preview' = {
  name: 'us-web-og-${toLower(suffix)}'
  parent: URLShortenerCdnProfile
  properties: {
    healthProbeSettings: {
      probeIntervalInSeconds: 100
      probePath: '/'
      probeProtocol: 'Https'
      probeRequestType: 'HEAD'
    }
    loadBalancingSettings: {
      additionalLatencyInMilliseconds: 50
      sampleSize: 4
      successfulSamplesRequired: 3
    }
    sessionAffinityState: 'Disabled'
  }
}

// Create Front Door Web Origin
resource URLShortenerWebOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2022-05-01-preview' = {
  name: 'us-web-origin-${toLower(suffix)}'
  parent: URLShortenerWebOriginGroup
  properties: {
    httpPort: 80
    httpsPort: 443
    hostName: URLShortenerWebsite.properties.defaultHostname
    originHostHeader: URLShortenerWebsite.properties.defaultHostname
    priority: 1
    weight: 1000
  }
}

// Create Front Door API Origin Group
resource URLShortenerApiOriginGroup 'Microsoft.Cdn/profiles/originGroups@2022-05-01-preview' = {
  name: 'us-api-og-${toLower(suffix)}'
  parent: URLShortenerCdnProfile
  properties: {
    loadBalancingSettings: {
      additionalLatencyInMilliseconds: 50
      sampleSize: 4
      successfulSamplesRequired: 3
    }
    sessionAffinityState: 'Disabled'
  }
}

// Create Front Door API Origin
resource URLShortenerApiOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2022-05-01-preview' = {
  name: 'us-api-origin-${toLower(suffix)}'
  parent: URLShortenerApiOriginGroup
  properties: {
    httpPort: 80
    httpsPort: 443
    hostName: URLShortenerApiMgmt.properties.hostnameConfigurations[0].hostName
    originHostHeader: URLShortenerApiMgmt.properties.hostnameConfigurations[0].hostName
    priority: 1
    weight: 1000
    enforceCertificateNameCheck: true
    enabledState: 'Enabled'
  }
}

// Create Front Door CDN Rule Set
resource URLShortenerRuleSet 'Microsoft.Cdn/profiles/ruleSets@2022-11-01-preview' = {
  name: 'URLShortenerRuleSet'
  parent: URLShortenerCdnProfile
}

// Create Front Door Rule for API
resource URLShortenerAPIRule 'Microsoft.Cdn/profiles/ruleSets/rules@2022-11-01-preview' = {
  name: 'APIRule'
  parent: URLShortenerRuleSet
  dependsOn: [ URLShortenerApiOrigin ]
  properties: {
    matchProcessingBehavior: 'Stop'
    actions: [
      {
        name: 'RouteConfigurationOverride'
        parameters: {
          originGroupOverride: {
            forwardingProtocol: 'HttpsOnly'
            originGroup: {
              id: URLShortenerApiOriginGroup.id
            }
          }
          typeName: 'DeliveryRuleRouteConfigurationOverrideActionParameters'
        }
      }
    ]
    conditions: [
      {
        name: 'UrlPath'
        parameters: {
          matchValues: [
            'api'
          ]
          operator: 'BeginsWith'
          negateCondition: false
          typeName: 'DeliveryRuleUrlPathMatchConditionParameters'
        }
      }
    ]
    order: 0
  }
}

// Create Front Door Rule for Redirect
resource URLShortenerRedirectRule 'Microsoft.Cdn/profiles/ruleSets/rules@2022-11-01-preview' = {
  name: 'RedirectRule'
  parent: URLShortenerRuleSet
  dependsOn: [ URLShortenerApiOrigin ]
  properties: {
    matchProcessingBehavior: 'Stop'
    actions: [
      {
        name: 'RouteConfigurationOverride'
        parameters: {
          originGroupOverride: {
            forwardingProtocol: 'HttpsOnly'
            originGroup: {
              id: URLShortenerApiOriginGroup.id
            }
          }
          typeName: 'DeliveryRuleRouteConfigurationOverrideActionParameters'
        }
      }
    ]
    conditions: [
      {
        name: 'UrlPath'
        parameters: {
          matchValues: [
            '^[A-Za-z0-9]{8}$'
          ]
          operator: 'RegEx'
          negateCondition: false
          typeName: 'DeliveryRuleUrlPathMatchConditionParameters'
        }
      }
    ]
    order: 1
  }
}

// Create default Front Door Rule
resource URLShortenerDefaultRule 'Microsoft.Cdn/profiles/ruleSets/rules@2022-11-01-preview' = {
  name: 'DefaultRule'
  parent: URLShortenerRuleSet
  dependsOn: [ URLShortenerWebOrigin ]
  properties: {
    matchProcessingBehavior: 'Continue'
    actions: [
      {
        name: 'RouteConfigurationOverride'
        parameters: {
          originGroupOverride: {
            forwardingProtocol: 'HttpsOnly'
            originGroup: {
              id: URLShortenerWebOriginGroup.id
            }
          }
          typeName: 'DeliveryRuleRouteConfigurationOverrideActionParameters'
        }
      }
    ]
    order: 2
  }
}

// Create Front Door CDN Route
resource URLShortenerAfdRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2022-05-01-preview' = {
  name: 'us-cdn-route-${toLower(suffix)}'
  parent: URLShortenerCdnEndpoint
  dependsOn: [ 
    URLShortenerAPIRule
    URLShortenerRedirectRule
    URLShortenerDefaultRule
  ]
  properties: {
    enabledState: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    customDomains: [
      {
        id: URLShortenerCustomDomain.id
      }
    ]
    patternsToMatch: [
      '/*'
    ]
    originGroup: {
      id: URLShortenerWebOriginGroup.id
    }
    ruleSets: [
      {
        id: URLShortenerRuleSet.id
      }
    ]
    supportedProtocols: [
      'Https'
    ]
    linkToDefaultDomain: 'Enabled'
  }
}

// Obtain existing DNS Zone [Optional]
resource existingDnsZone 'Microsoft.Network/dnszones@2018-05-01' existing = if (dnsZone != 'DoNotUse') {
  name: dnsZone
  scope: resourceGroup(dnsZoneRG)
}

// Create Front Door custom domain [Optional]
resource URLShortenerCustomDomain 'Microsoft.Cdn/profiles/customDomains@2022-05-01-preview' = if (dnsZone != 'DoNotUse') {
  name: 'us-cdn-cd-${toLower(suffix)}'
  parent: URLShortenerCdnProfile
  properties: {
    azureDnsZone: {
      id: existingDnsZone.id
    }
    hostName: dnsZone
    tlsSettings: {
      certificateType: 'ManagedCertificate'
      minimumTlsVersion: 'TLS12'
    }
  }
}

// Create the Front Door DNS records using module [Optional]
module dnsRecords './dns-records.bicep' = if (dnsZone != 'DoNotUse') {
  name: 'frontdoor-dns-records'
  scope: resourceGroup(dnsZoneRG)    // Deployed in the scope of DNS Zone resource group
  params: {
    dnsZone: dnsZone
    validationToken: URLShortenerCustomDomain.properties.validationProperties.validationToken
    cdnEndpointId: URLShortenerCdnEndpoint.id
  }
}

// Create App Service Plan
resource serverFarm 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: 'us-asp-${toLower(suffix)}'
  location: location
  tags: tagName
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

// Create Log Analytics Workspace
resource logAnalyticsWksp 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'us-law-${toLower(suffix)}'
  location: location
  tags: tagName
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    retentionInDays: 30
    sku: {
      name: 'pergb2018'
    }
    workspaceCapping: {
      dailyQuotaGb: -1
    }
  }
}

// Create App Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'us-ai-${toLower(suffix)}'
  location: location
  tags: tagName
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Flow_Type: 'Bluefield'
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    Request_Source: 'rest'
    RetentionInDays: 30
    WorkspaceResourceId: logAnalyticsWksp.id
  }
}

// Create Function App
resource URLShortenerFunctionApp 'Microsoft.Web/sites@2022-03-01' = {
  name: 'us-fa-${toLower(suffix)}'
  location: location
  kind: 'functionapp,linux'
  tags: tagName
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    clientAffinityEnabled: false
    serverFarmId: serverFarm.id
    enabled: true
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${listKeys(storageAccount.id, storageAccount.apiVersion).keys[0].value}'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: 'InstrumentationKey=${appInsights.properties.InstrumentationKey}'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'RESOURCE_GROUP'
          value: resourceGroup().name
        }
        {
          name: 'DATABASE_ACCOUNT_NAME'
          value: dbAccount.name
        }
        {
          name: 'DATABASE_CONTAINER'
          value: dbContainer.name
        }
        {
          name: 'DATABASE_NAME'
          value: database.name
        }
        {
          name: 'DATABASE_URL'
          value: dbAccount.properties.documentEndpoint
        }
        {
          name: 'SHORT_URL'
          value: shortUrl
        }
      ]
      linuxFxVersion: 'Python|3.9'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

var roleAssignmentId = guid('sql-role-assignment', resourceGroup().id, dbAccount.id)

// Create Cosmos DB Role Assignment for Function App
resource dbRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2022-08-15' = {
  name: roleAssignmentId
  parent: dbAccount
  properties: {
    principalId: URLShortenerFunctionApp.identity.principalId
    roleDefinitionId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${dbAccount.name}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: dbAccount.id
  }
}

// Create API Management
resource URLShortenerApiMgmt 'Microsoft.ApiManagement/service@2021-12-01-preview' = {
  name: 'us-apim-${toLower(suffix)}'
  location: location
  tags: tagName
  sku: {
    capacity: 0
    name: 'Consumption'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hostnameConfigurations: [
      {
        type: 'Proxy'
        hostName: 'us-apim-${toLower(suffix)}.azure-api.net'
        negotiateClientCertificate: false
        defaultSslBinding: true
        certificateSource: 'BuiltIn'
      }
    ]
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2': 'false'
    }
    disableGateway: false
    publisherEmail: 'no-reply@example.com'
    publisherName: 'Self Hosting'
    publicNetworkAccess: 'Enabled'
  }
}

var ApimRoleAssignmentId = guid('apim-role-assignment', resourceGroup().id, dbAccount.id)

// Create Cosmos DB Role Assignment for API Management
resource ApimRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2022-08-15' = {
  name: ApimRoleAssignmentId
  parent: dbAccount
  properties: {
    principalId: URLShortenerApiMgmt.identity.principalId
    roleDefinitionId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${dbAccount.name}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: dbAccount.id
  }
}

var defaultHostKey = listkeys('${URLShortenerFunctionApp.id}/host/default', '2022-03-01').functionKeys.default

// Create API Management Named Value to store Function Key
resource apiNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-12-01-preview' = {
  name: 'us-func-key-${toLower(suffix)}'
  parent: URLShortenerApiMgmt
  properties: {
    displayName: 'us-function-key-${toLower(suffix)}'
    secret: true
    tags: [
      'URLShortener'
      'FunctionKey'
    ]
    value: defaultHostKey
  }
}

// Create API Management Backend pointing to Function App
resource apiBackend 'Microsoft.ApiManagement/service/backends@2021-12-01-preview' = { 
  name: 'us-backend-${toLower(suffix)}'
  parent: URLShortenerApiMgmt
  properties: {
    credentials: {
      header: {
        'x-functions-key': ['{{${apiNamedValue.name}}}']
      }
    }
    description: 'URLShortener Backend Function'
    protocol: 'http'
    resourceId: '${environment().resourceManager}${URLShortenerFunctionApp.id}'
    title: 'URLShortener-Backend-Function'
    url: 'https://${URLShortenerFunctionApp.properties.defaultHostName}'
    tls:{
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// Create API Management API
resource URLShortenerApi 'Microsoft.ApiManagement/service/apis@2021-12-01-preview' = {
  name: 'us-api-${toLower(suffix)}'
  parent: URLShortenerApiMgmt
  properties: {
    apiType: 'http'
    description: 'URLShortener API'
    displayName: 'URLShortener API'
    isCurrent: true
    path: '/'
    protocols: [
      'https'
    ]
    serviceUrl: URLShortenerApiMgmt.properties.gatewayUrl
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
    subscriptionRequired: true
    type: 'http'
  }
}

// Configure Logging for API Management
resource URLShortenerApiLogger 'Microsoft.ApiManagement/service/loggers@2021-12-01-preview' = {
  name: 'us-api-log-${toLower(suffix)}'
  parent: URLShortenerApiMgmt
  properties: {
    description: 'Log URLShortener API on Application Insights'
    isBuffered: true
    loggerType: 'applicationInsights'
    resourceId: appInsights.id
    credentials:{
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
  }
}

// Create API Management Product
resource URLShortenerApiProduct 'Microsoft.ApiManagement/service/products@2021-12-01-preview' = {
  name: 'us-product-${toLower(suffix)}'
  parent: URLShortenerApiMgmt
  properties: {
    displayName: 'URLShortener'
    description: 'Backend API for URLShortener'
    subscriptionRequired: false
    state: 'published'
  }
}

// Create API Management Product Map
resource URLShortenerApiProductMap 'Microsoft.ApiManagement/service/products/apis@2021-12-01-preview' = {
  name: '${URLShortenerApiMgmt.name}/${URLShortenerApiProduct.name}/${URLShortenerApi.name}'
}

// Create API Management Subscription
resource URLShortenerApiSubscription 'Microsoft.ApiManagement/service/subscriptions@2021-12-01-preview' = {
  name: 'us-api-sub-${toLower(suffix)}'
  parent: URLShortenerApiMgmt
  properties: {
    scope: '/apis/${URLShortenerApi.id}'
    displayName: 'All access subscription'
    state: 'active'
    allowTracing: true
  }
}

// Create API to GET the long URL for the provided short URL ID
resource URLShortenerApiGetURLId 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'get-url-by-id'
  parent: URLShortenerApi
  properties: {
    description: 'API to get the long URL for the provided short URL'
    displayName: 'Get URL by Id'
    method: 'GET'
    templateParameters: [
      {
        name: 'id'
        required: true
        type: 'string'
      }
    ]
    urlTemplate: '/{id}'
  }
}

// Create API Policy for GET URL by ID
resource URLShortenerApiGetURLIdPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: URLShortenerApiGetURLId
  name: 'policy'
  properties: {
    value: '<policies>\r\n    <inbound>\r\n        <base />\r\n        <check-header name="X-Azure-FDID" failed-check-httpcode="403" failed-check-error-message="Not Authorized" ignore-case="true">\r\n            <value>${URLShortenerCdnProfile.properties.frontDoorId}</value>\r\n        </check-header>\r\n        <set-backend-service base-url="https://${dbAccount.name}.documents.azure.com" />\r\n        <set-variable name="requestDateString" value="@(DateTime.UtcNow.ToString("r"))" />\r\n        <authentication-managed-identity resource="https://${dbAccount.name}.documents.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />\r\n        <set-header name="Authorization" exists-action="override">\r\n            <value>@("type=aad&ver=1.0&sig=" + context.Variables["msi-access-token"])</value>\r\n        </set-header>\r\n        <set-header name="x-ms-date" exists-action="override">\r\n            <value>@(context.Variables.GetValueOrDefault<string>("requestDateString"))</value>\r\n        </set-header>\r\n        <set-header name="x-ms-version" exists-action="override">\r\n            <value>2018-12-31</value>\r\n        </set-header>\r\n        <set-header name="x-ms-documentdb-partitionkey" exists-action="override">\r\n            <value>@{string str = "[ \\"" + context.Request.OriginalUrl.Path.Trim(\'/\') + "\\" ]\'";return str;}</value>\r\n        </set-header>\r\n        <rewrite-uri template="/dbs/${database.name}/colls/${dbContainer.name}/docs/{id}" copy-unmatched-params="false" />\r\n    </inbound>\r\n    <backend>\r\n        <base />\r\n    </backend>\r\n    <outbound>\r\n        <base />\r\n        <return-response>\r\n            <set-status code="302" reason="Found" />\r\n            <set-header name="Location" exists-action="override">\r\n                <value>@{var res_json = context.Response.Body.As<JObject>(preserveContent: true);return res_json["target_url"].ToString();}</value>\r\n            </set-header>\r\n        </return-response>\r\n    </outbound>\r\n    <on-error>\r\n        <base />\r\n    </on-error>\r\n</policies>\r\n'
    format: 'rawxml'
  }
}

// Create API to HEAD the long URL for the provided short URL ID
resource URLShortenerApiHeadURLId 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'head-url-by-id'
  parent: URLShortenerApi
  properties: {
    description: 'API to get the long URL for the provided short URL for HEAD request'
    displayName: 'HEAD URL by Id'
    method: 'HEAD'
    templateParameters: [
      {
        name: 'id'
        required: true
        type: 'string'
      }
    ]
    urlTemplate: '/{id}'
  }
}

// Create API Policy for GET URL by ID
resource URLShortenerApiHeadURLIdPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: URLShortenerApiHeadURLId
  name: 'policy'
  properties: {
    value: '<policies>\r\n    <inbound>\r\n        <base />\r\n        <check-header name="X-Azure-FDID" failed-check-httpcode="403" failed-check-error-message="Not Authorized" ignore-case="true">\r\n            <value>${URLShortenerCdnProfile.properties.frontDoorId}</value>\r\n        </check-header>\r\n        <set-backend-service base-url="https://${dbAccount.name}.documents.azure.com" />\r\n        <set-variable name="requestDateString" value="@(DateTime.UtcNow.ToString("r"))" />\r\n        <authentication-managed-identity resource="https://${dbAccount.name}.documents.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />\r\n        <set-header name="Authorization" exists-action="override">\r\n            <value>@("type=aad&ver=1.0&sig=" + context.Variables["msi-access-token"])</value>\r\n        </set-header>\r\n        <set-header name="x-ms-date" exists-action="override">\r\n            <value>@(context.Variables.GetValueOrDefault<string>("requestDateString"))</value>\r\n        </set-header>\r\n        <set-header name="x-ms-version" exists-action="override">\r\n            <value>2018-12-31</value>\r\n        </set-header>\r\n        <set-header name="x-ms-documentdb-partitionkey" exists-action="override">\r\n            <value>@{string str = "[ \\"" + context.Request.OriginalUrl.Path.Trim(\'/\') + "\\" ]\'";return str;}</value>\r\n        </set-header>\r\n        <set-method>GET</set-method>\r\n        <rewrite-uri template="/dbs/${database.name}/colls/${dbContainer.name}/docs/{id}" copy-unmatched-params="false" />\r\n    </inbound>\r\n    <backend>\r\n        <base />\r\n    </backend>\r\n    <outbound>\r\n        <base />\r\n        <return-response>\r\n            <set-status code="200" reason="Ok" />\r\n            <set-header name="Location" exists-action="override">\r\n                <value>@{var res_json = context.Response.Body.As<JObject>(preserveContent: true);return res_json["target_url"].ToString();}</value>\r\n            </set-header>\r\n        </return-response>\r\n    </outbound>\r\n    <on-error>\r\n        <base />\r\n    </on-error>\r\n</policies>\r\n'
    format: 'rawxml'
  }
}

// Create API to POST the long URL to create a short URL
resource URLShortenerApiPostShortenURL 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'shorten-url'
  parent: URLShortenerApi
  properties: {
    description: 'API to create short URL'
    displayName: 'Create Short URL'
    method: 'POST'
    responses: [
      {
        description: 'Shortened URL'
        statusCode: 200
      }
    ]
    urlTemplate: '/api/shorten-url'
  }
}

// Create API Policy for POST Shorten URL
resource URLShortenerApiPostShortenURLPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: URLShortenerApiPostShortenURL
  name: 'policy'
  properties: {
    value: '<policies>\r\n    <inbound>\r\n        <base />\r\n        <cors allow-credentials="true">\r\n            <allowed-origins>\r\n                <origin>https://${URLShortenerCdnEndpoint.properties.hostName}</origin>\r\n                <origin>${URLShortenerApiMgmt.properties.gatewayUrl}</origin>\r\n                            <origin>${shortUrl}</origin>\r\n            </allowed-origins>\r\n            <allowed-methods preflight-result-max-age="120">\r\n                <method>POST</method>\r\n                <method>OPTIONS</method>\r\n            </allowed-methods>\r\n            <allowed-headers>\r\n                <header>*</header>\r\n            </allowed-headers>\r\n            <expose-headers>\r\n                <header>*</header>\r\n            </expose-headers>\r\n        </cors>\r\n        <check-header name="X-Azure-FDID" failed-check-httpcode="403" failed-check-error-message="Not Authorized" ignore-case="true">\r\n            <value>${URLShortenerCdnProfile.properties.frontDoorId}</value>\r\n        </check-header>\r\n        <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized. Access token is missing or invalid." require-expiration-time="true" require-scheme="Bearer" require-signed-tokens="true" clock-skew="300" output-token-variable-name="jwt-token">\r\n            <openid-config url="https://${aadB2cOrg}.b2clogin.com/${aadB2cOrg}.onmicrosoft.com/v2.0/.well-known/openid-configuration?p=${aadB2cUserFlow}" />\r\n            <required-claims>\r\n                <claim name="aud">\r\n                    <value>${aadB2cApiClientId}</value>\r\n                </claim>\r\n            </required-claims>\r\n        </validate-jwt>\r\n        <set-header name="Content-Type" exists-action="override">\r\n            <value>application/json</value>\r\n        </set-header>\r\n        <set-variable name="userID" value="@{\r\n            var authHeader = context.Request.Headers.GetValueOrDefault("Authorization", "");\r\n            return (string)authHeader.AsJwt()?.Claims.GetValueOrDefault("oid", "DOESNOT_EXIST");\r\n        }" />\r\n        <set-body template="liquid">\r\n            {\r\n                "url": "{{ body.url }}",\r\n                "custom_hash": "{{body.custom_hash | ""}}",\r\n                "oid": "{{context.Variables["userID"]}}",\r\n            "existing_id": "{{body.existing_id | ""}}"\r\n            }\r\n        </set-body>\r\n        <set-backend-service id="apim-generated-policy" backend-id="${apiBackend.name}" />\r\n        <rewrite-uri template="/api/shorten-url" />\r\n    </inbound>\r\n    <backend>\r\n        <base />\r\n    </backend>\r\n    <outbound>\r\n        <base />\r\n    </outbound>\r\n    <on-error>\r\n        <base />\r\n    </on-error>\r\n</policies>\r\n'
    format: 'rawxml'
  }
}

// Create API to GET the list of URLs for a specific User
resource URLShortenerApiGetListURLs 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'list-urls'
  parent: URLShortenerApi
  properties: {
    description: 'API to get the list of URLS for that specific User'
    displayName: 'List URLs'
    method: 'GET'
    responses: [
      {
        description: 'List of URLs specific to this User'
        statusCode: 200
      }
    ]
    urlTemplate: '/api/list-urls'
  }
}

// Create API Policy for GET List URLs
resource URLShortenerApiGetListURLsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: URLShortenerApiGetListURLs
  name: 'policy'
  properties: {
    value: '<policies>\r\n    <inbound>\r\n        <base />\r\n        <cors allow-credentials="true">\r\n            <allowed-origins>\r\n                <origin>https://${URLShortenerCdnEndpoint.properties.hostName}</origin>\r\n                <origin>${URLShortenerApiMgmt.properties.gatewayUrl}</origin>\r\n                            <origin>${shortUrl}</origin>\r\n            </allowed-origins>\r\n            <allowed-methods preflight-result-max-age="120">\r\n                <method>GET</method>\r\n                <method>OPTIONS</method>\r\n            </allowed-methods>\r\n            <allowed-headers>\r\n                <header>*</header>\r\n            </allowed-headers>\r\n            <expose-headers>\r\n                <header>*</header>\r\n            </expose-headers>\r\n        </cors>\r\n        <check-header name="X-Azure-FDID" failed-check-httpcode="403" failed-check-error-message="Not Authorized" ignore-case="true">\r\n            <value>${URLShortenerCdnProfile.properties.frontDoorId}</value>\r\n        </check-header>\r\n        <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized. Access token is missing or invalid." require-expiration-time="true" require-scheme="Bearer" require-signed-tokens="true" clock-skew="300" output-token-variable-name="jwt-token">\r\n            <openid-config url="https://${aadB2cOrg}.b2clogin.com/${aadB2cOrg}.onmicrosoft.com/v2.0/.well-known/openid-configuration?p=${aadB2cUserFlow}" />\r\n            <required-claims>\r\n                <claim name="aud">\r\n                    <value>${aadB2cApiClientId}</value>\r\n                </claim>\r\n            </required-claims>\r\n        </validate-jwt>\r\n        <set-variable name="userID" value="@{\r\n            var authHeader = context.Request.Headers.GetValueOrDefault("Authorization", "");\r\n            return (string)authHeader.AsJwt()?.Claims.GetValueOrDefault("oid", "DOESNOT_EXIST");\r\n        }" />\r\n        <set-header name="Content-Type" exists-action="override">\r\n            <value>application/json</value>\r\n        </set-header>\r\n        <set-method>POST</set-method>\r\n        <set-body template="liquid">{"oid": "{{context.Variables["userID"]}}"}</set-body>\r\n        <set-backend-service id="apim-generated-policy" backend-id="${apiBackend.name}" />\r\n        <rewrite-uri template="/api/list-urls" />\r\n    </inbound>\r\n    <backend>\r\n        <base />\r\n    </backend>\r\n    <outbound>\r\n        <base />\r\n    </outbound>\r\n    <on-error>\r\n        <base />\r\n    </on-error>\r\n</policies>\r\n'
    format: 'rawxml'
  }
}

// Create API to GET the list of URLs without check for a specific User
resource URLShortenerApiGetNoCheckListURLs 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'list-urls-nocheck'
  parent: URLShortenerApi
  properties: {
    description: 'API to get the list of URLS for that specific User without check'
    displayName: 'List URLs Without Check'
    method: 'GET'
    responses: [
      {
        description: 'List of URLs specific to this User without check'
        statusCode: 200
      }
    ]
    urlTemplate: '/api/list-urls-nocheck'
  }
}

// Create API Policy for GET List URLs
resource URLShortenerApiGetNoCheckListURLsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: URLShortenerApiGetNoCheckListURLs
  name: 'policy'
  properties: {
    value: '<policies>\r\n    <inbound>\r\n        <base />\r\n        <cors allow-credentials="true">\r\n            <allowed-origins>\r\n                <origin>https://${URLShortenerCdnEndpoint.properties.hostName}</origin>\r\n                <origin>${URLShortenerApiMgmt.properties.gatewayUrl}</origin>\r\n                            <origin>${shortUrl}</origin>\r\n            </allowed-origins>\r\n            <allowed-methods preflight-result-max-age="120">\r\n                <method>GET</method>\r\n                <method>OPTIONS</method>\r\n            </allowed-methods>\r\n            <allowed-headers>\r\n                <header>*</header>\r\n            </allowed-headers>\r\n            <expose-headers>\r\n                <header>*</header>\r\n            </expose-headers>\r\n        </cors>\r\n        <check-header name="X-Azure-FDID" failed-check-httpcode="403" failed-check-error-message="Not Authorized" ignore-case="true">\r\n            <value>${URLShortenerCdnProfile.properties.frontDoorId}</value>\r\n        </check-header>\r\n        <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized. Access token is missing or invalid." require-expiration-time="true" require-scheme="Bearer" require-signed-tokens="true" clock-skew="300" output-token-variable-name="jwt-token">\r\n            <openid-config url="https://${aadB2cOrg}.b2clogin.com/${aadB2cOrg}.onmicrosoft.com/v2.0/.well-known/openid-configuration?p=${aadB2cUserFlow}" />\r\n            <required-claims>\r\n                <claim name="aud">\r\n                    <value>${aadB2cApiClientId}</value>\r\n                </claim>\r\n            </required-claims>\r\n        </validate-jwt>\r\n        <set-variable name="userID" value="@{\r\n            var authHeader = context.Request.Headers.GetValueOrDefault("Authorization", "");\r\n            return (string)authHeader.AsJwt()?.Claims.GetValueOrDefault("oid", "DOESNOT_EXIST");\r\n        }" />\r\n        <set-header name="Content-Type" exists-action="override">\r\n            <value>application/query+json</value>\r\n        </set-header>\r\n        <set-method>POST</set-method>\r\n        <set-backend-service base-url="https://${dbAccount.name}.documents.azure.com" />\r\n        <set-variable name="requestDateString" value="@(DateTime.UtcNow.ToString("r"))" />\r\n        <authentication-managed-identity resource="https://${dbAccount.name}.documents.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />\r\n        <set-header name="Authorization" exists-action="override">\r\n            <value>@("type=aad&ver=1.0&sig=" + context.Variables["msi-access-token"])</value>\r\n        </set-header>\r\n        <set-header name="x-ms-date" exists-action="override">\r\n            <value>@(context.Variables.GetValueOrDefault<string>("requestDateString"))</value>\r\n        </set-header>\r\n        <set-header name="x-ms-version" exists-action="override">\r\n            <value>2018-12-31</value>\r\n        </set-header>\r\n        <set-header name="x-ms-documentdb-isquery" exists-action="override">\r\n            <value>True</value>\r\n        </set-header>\r\n        <set-header name="x-ms-documentdb-query-enablecrosspartition" exists-action="override">\r\n            <value>True</value>\r\n        </set-header>\r\n        <set-body template="liquid">\r\n        {\r\n            "query": "SELECT c.id, c.target_url FROM c WHERE (c.oid = \'{{context.Variables["userID"]}}\')",\r\n            "parameters": []}\r\n        </set-body>\r\n        <rewrite-uri template="/dbs/${database.name}/colls/${dbContainer.name}/docs/" />\r\n    </inbound>\r\n    <backend>\r\n        <base />\r\n    </backend>\r\n    <outbound>\r\n        <base />\r\n    </outbound>\r\n    <on-error>\r\n        <base />\r\n    </on-error>\r\n</policies>\r\n'
    format: 'rawxml'
  }
}

// Create API to Delete an URL
resource URLShortenerApiDeleteURL 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'delete-url'
  parent: URLShortenerApi
  properties: {
    description: 'API to delete a specific URL'
    displayName: 'Delete URL'
    method: 'DELETE'
    templateParameters: [
      {
        name: 'id'
        required: true
        type: 'string'
      }
    ]
    urlTemplate: '/api/delete-url/{id}'
  }
}

// Create API Policy to delete an URL
resource URLShortenerApiDeleteURLPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: URLShortenerApiDeleteURL
  name: 'policy'
  properties: {
    value: '<policies>\r\n    <inbound>\r\n        <base />\r\n        <cors allow-credentials="true">\r\n            <allowed-origins>\r\n                <origin>https://${URLShortenerCdnEndpoint.properties.hostName}</origin>\r\n                <origin>${URLShortenerApiMgmt.properties.gatewayUrl}</origin>\r\n                            <origin>${shortUrl}</origin>\r\n            </allowed-origins>\r\n            <allowed-methods preflight-result-max-age="120">\r\n                <method>DELETE</method>\r\n                </allowed-methods>\r\n            <allowed-headers>\r\n                <header>*</header>\r\n            </allowed-headers>\r\n            <expose-headers>\r\n                <header>*</header>\r\n            </expose-headers>\r\n        </cors>\r\n        <check-header name="X-Azure-FDID" failed-check-httpcode="403" failed-check-error-message="Not Authorized" ignore-case="true">\r\n            <value>${URLShortenerCdnProfile.properties.frontDoorId}</value>\r\n        </check-header>\r\n        <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized. Access token is missing or invalid." require-expiration-time="true" require-scheme="Bearer" require-signed-tokens="true" clock-skew="300" output-token-variable-name="jwt-token">\r\n            <openid-config url="https://${aadB2cOrg}.b2clogin.com/${aadB2cOrg}.onmicrosoft.com/v2.0/.well-known/openid-configuration?p=${aadB2cUserFlow}" />\r\n            <required-claims>\r\n                <claim name="aud">\r\n                    <value>${aadB2cApiClientId}</value>\r\n                </claim>\r\n            </required-claims>\r\n        </validate-jwt>\r\n        <set-variable name="userID" value="@{\r\n            var authHeader = context.Request.Headers.GetValueOrDefault("Authorization", "");\r\n            return (string)authHeader.AsJwt()?.Claims.GetValueOrDefault("oid", "DOESNOT_EXIST");\r\n        }" />\r\n        <set-backend-service base-url="https://${dbAccount.name}.documents.azure.com" />\r\n        <set-variable name="requestDateString" value="@(DateTime.UtcNow.ToString("r"))" />\r\n        <authentication-managed-identity resource="https://${dbAccount.name}.documents.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />\r\n        <set-header name="Authorization" exists-action="override">\r\n            <value>@("type=aad&ver=1.0&sig=" + context.Variables["msi-access-token"])</value>\r\n        </set-header>\r\n        <set-header name="x-ms-date" exists-action="override">\r\n            <value>@(context.Variables.GetValueOrDefault<string>("requestDateString"))</value>\r\n        </set-header>\r\n        <set-header name="x-ms-version" exists-action="override">\r\n            <value>2018-12-31</value>\r\n        </set-header>\r\n        <set-header name="x-ms-documentdb-partitionkey" exists-action="override">\r\n            <value>@{string str = "[ \\"" + context.Request.OriginalUrl.Path.Trim(\'/\').Split(\'/\').Last() + "\\" ]\'";return str;}</value>\r\n        </set-header>\r\n        <rewrite-uri template="/dbs/${database.name}/colls/${dbContainer.name}/docs/{id}" copy-unmatched-params="false" />\r\n    </inbound>\r\n    <backend>\r\n        <base />\r\n    </backend>\r\n    <outbound>\r\n        <base />\r\n    </outbound>\r\n    <on-error>\r\n        <base />\r\n    </on-error>\r\n</policies>\r\n'
    format: 'rawxml'
  }
}

// Enable Diagnostics for API Management
resource URLShortenerApiDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2021-12-01-preview' = {
  parent: URLShortenerApiMgmt
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'Legacy'
    logClientIp: true
    loggerId: URLShortenerApiLogger.id
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        dataMasking: {
          queryParams: [
            {
              value: '*'
              mode: 'Hide'
            }
          ]
        }
      }
    }
    backend: {
      request: {
        dataMasking: {
          queryParams: [
            {
              value: '*'
              mode: 'Hide'
            }
          ]
        }
      }
    }
  }
}

// Enable Diagnostics for APIs
resource URLShortenerServiceApiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2021-12-01-preview' = {
  parent: URLShortenerApi
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'Legacy'
    verbosity: 'information'
    logClientIp: true
    loggerId: URLShortenerApiLogger.id
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
  }
}

// Output the required information
output FrontDoorEndpoint string = 'https://${URLShortenerCdnEndpoint.properties.hostName}'
output ApiMgmtEndpoint string = URLShortenerApiMgmt.properties.gatewayUrl
output functionApp string = URLShortenerFunctionApp.name
