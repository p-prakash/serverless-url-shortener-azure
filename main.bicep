// Setting subscription as scope
targetScope = 'subscription'

// Parameters
@description('Name of the API environment')
param Environ string

@description('Azure Region where the API should be deployed')
param location string

@description('Azure AD B2C Tenant Name')
@maxLength(27)
param aadB2cOrg string

@description('Azure AD B2C User Flow Name for Sign Up and Sign In')
@minLength(7)
param aadB2cUserFlow string

@description('Azure AD B2C App Client Id')
@minLength(36)
@maxLength(36)
param aadB2cApiClientId string

@description('URL for shortening domain')
@minLength(7)
param shortUrl string

// Create the resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'url-shortener-rg'
  location: location
  tags: {
    Reason: 'url-shortener-${toLower(Environ)}'
    Environment: Environ
  }
}

// Create the URL Shortener backend using module
module shorten './url-shortener.bicep' = {
  name: 'url-shortener'
  scope: rg    // Deployed in the scope of resource group we created above
  params: {
    Environ: Environ
    location: location
    aadB2cOrg: aadB2cOrg
    aadB2cUserFlow: aadB2cUserFlow
    aadB2cApiClientId: aadB2cApiClientId
    shortUrl: shortUrl
  }
}

output applicationURL string = shorten.outputs.applicationURL
output apiEndpoint string = shorten.outputs.apiEndpoint
output storageAccount string = shorten.outputs.storageAccount
output resourceGroup string = rg.name
output functionApp string = shorten.outputs.functionApp
