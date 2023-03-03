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

@description('DNS Zone for shortening domain')
param dnsZone string = 'DoNotUse'

@description('Resource Group of the DNS Zone')
param dnsZoneRG string = 'DoNotUse'

@description('GitHub URL of the static web apps repository')
param repoURL string

@description('GitHub access Token')
@secure()
param repoToken string

@description('Suffix to add to the resources')
@minLength(8)
@maxLength(8)
param suffix string

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
    repoToken: repoToken
    repoURL: repoURL
    suffix: suffix
    dnsZone: dnsZone
    dnsZoneRG: dnsZoneRG
  }
}

output functionApp string = shorten.outputs.functionApp
