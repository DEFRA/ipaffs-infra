param location string
param aksVnetName string
param aksSubnetName string
param adminUsername string = 'ipaffsadmin'
@secure()
param jumpboxPassword string

//param keyVaultName string = 'pocimpinfkv1401'
//param sshKeySecretName string = 'aks-ssh-public'

@secure()
param sshPublicKey string


resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: aksVnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: aksSubnetName
  parent: vnet
}
/*
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}
*/

resource nic 'Microsoft.Network/networkInterfaces@2022-07-01' = {
  name: 'jumpbox-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnet.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: 'jumpbox-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    osProfile: {
      computerName: 'jumpbox'
      adminUsername: adminUsername
      adminPassword: jumpboxPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
//              keyData: '@Microsoft.KeyVault(SecretUri=${keyVault.properties.vaultUri}${sshKeySecretName})'
//              keyData: '@Microsoft.KeyVault(SecretUri=${keyVault.properties.vaultUri}secrets/${sshKeySecretName})'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-focal'
        sku: '20_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}
