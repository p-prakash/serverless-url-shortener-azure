@description('DNS Zone for shortening domain')
param dnsZone string

@description('DNS Zone validation Token')
param validationToken string

@description('Front Door Endpoint Id')
param cdnEndpointId string

// Obtain existing DNS Zone
resource existingDnsZone 'Microsoft.Network/dnszones@2018-05-01' existing = {
  name: dnsZone
}

// Create Validation Text Record
resource validationTextRecord 'Microsoft.Network/dnszones/TXT@2018-05-01' = {
  name: '_dnsauth'
  parent: existingDnsZone
  properties: {
    TTL: 300
    TXTRecords: [
      {
        value: [
          validationToken
        ]
      }
    ]
  }
}

// Create DNS A Record
resource dnsARecord 'Microsoft.Network/dnszones/A@2018-05-01' = {
  name: '@'
  parent: existingDnsZone
  properties: {
    targetResource: {
      id: cdnEndpointId
    }
    TTL: 60
  }
}
