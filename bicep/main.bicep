param location string = resourceGroup().location
param sshKeySecretName string = 'aks-ssh-public'
param keyVaultName string = 'POCIMPINFKV1401'
param aksClusterName string = 'POCIMPINFAK1401'
param aksVnetName string = 'POCIMPINFVN1401'
param aksSubnetName string = 'POCIMPINFSU1401'
param aksResourceGroupName string = 'POCIMPINFRG1401'
param tenantId string
param objectId string
param dnsPrefix string = 'ipaffsaks'
param acrName string = 'POCIMPINFAC1401'
//param bastionVnetName string = 'POCIMPINFVN1042'
//param bastionSubnetName string = 'AzureBastionSubnet'


@description('Admin username for AKS nodes and jumpbox')
param linuxAdminUsername string = 'ipaffsadmin'
//param sshPublicKey string = '@Microsoft.KeyVault(SecretUri=https://${keyVaultName}.vault.azure.net/secrets/${sshKeySecretName})'
@description('SSH public key to provision Linux VMs')
@secure()
param sshPublicKey string = loadTextContent('aks_id_rsa.pub')
//param sshRSAPublicKey string = '@Microsoft.KeyVault(SecretUri=https://pocimpinfkv1401.vault.azure.net/secrets/aks-ssh-public)'
//@secure()
//param jumpboxPassword string = '@Microsoft.KeyVault(SecretUri=https://POCIMPINFKV1401.vault.azure.net/secrets/jumpbox-password)'

module network 'network.bicep' = {
  name: 'deployNetwork'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    location: location
    aksVnetName: aksVnetName
    aksSubnetName: aksSubnetName
//    bastionVnetName: bastionVnetName
//    bastionSubnetName: bastionSubnetName
  }
}

module acr 'acr.bicep' = {
  name: 'createAcr'
  scope: resourceGroup(aksResourceGroupName)
  params: {
//    name: 'POCIMPINFAC1401'
    acrName: acrName
    location: location
    sku: 'Premium' // or 'Premium' if you need private endpoints
    adminEnabled: true
  }
//  dependsOn: [ network ]
}

module keyVault 'keyvault.bicep' = {
  name: 'deployKeyVault'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    name: 'POCIMPINFKV1401'
    location: location
    tenantId: tenantId
    objectId: objectId
  }
//  dependsOn: [ network ]
}

module aks 'aks-cluster.bicep' = {
  name: 'deployAksCluster'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    clusterName: aksClusterName
    dnsPrefix: dnsPrefix
    linuxAdminUsername: linuxAdminUsername
    sshPublicKey: sshPublicKey
    subnetId: network.outputs.aksSubnetId
    location: location
    acrName: acr.outputs.acrName
  }
  dependsOn: [keyVault]
}
/*
module bastion 'bastion.bicep' = {
  name: 'deployBastion'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    location: location
    bastionVnetName: bastionVnetName
    bastionSubnetName: bastionSubnetName
  }
  dependsOn: [ network ]
}

module jumpbox 'jumpbox.bicep' = {
  name: 'deployJumpbox'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    location: location
    aksVnetName: aksVnetName
    aksSubnetName: aksSubnetName
    adminUsername: 'ipaffsadmin'
    jumpboxPassword: jumpboxPassword
    sshPublicKey: sshPublicKey
//    keyVaultName: keyVaultName
//    sshKeySecretName: sshKeySecretName
  }
  dependsOn: [ network, keyVault ]
}
*/
module uploadSsh 'upload-ssh.bicep' = {
  name: 'uploadSshKey'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    keyVaultName: keyVaultName
    sshKeySecretName: sshKeySecretName
    sshPublicKey: loadTextContent('aks_id_rsa.pub')
  }
  dependsOn: [ keyVault ]
}
/*
module aksPeering 'aks-to-bastion.bicep' = {
  name: 'peerFromAks'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    aksVnetName: aksVnetName
    remoteVnetId: resourceId(aksResourceGroupName, 'Microsoft.Network/virtualNetworks', bastionVnetName)
  }
  dependsOn: [ network, bastion ]
}

module bastionPeering 'bastion-to-aks.bicep' = {
  name: 'peerFromBastion'
  scope: resourceGroup(aksResourceGroupName)
  params: {
    bastionVnetName: bastionVnetName
    remoteVnetId: resourceId(aksResourceGroupName, 'Microsoft.Network/virtualNetworks', aksVnetName)
  }
  dependsOn: [ network, bastion ]
}
*/



