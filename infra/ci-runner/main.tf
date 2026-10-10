locals {
  rg_id              = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
  storage_account_id = "${local.rg_id}/providers/Microsoft.Storage/storageAccounts/${var.state_storage_account_name}"
  runner_subnet      = cidrsubnet(var.address_space, 2, 0) # /26
  pe_subnet          = cidrsubnet(var.address_space, 3, 2) # /27
  tags               = { purpose = "github-actions-runner" }

  # One VM per consuming repository. "foundation" keeps the original resource names.
  runners = {
    for k in var.runners : k => {
      vm  = k == "foundation" ? "${var.name_prefix}-runner-01" : "${var.name_prefix}-${k}-runner-01"
      nic = k == "foundation" ? "${var.name_prefix}-runner-nic" : "${var.name_prefix}-${k}-runner-nic"
      key = k == "foundation" ? "${var.name_prefix}-runner-key" : "${var.name_prefix}-${k}-runner-key"
    }
  }
}

# ---- Network ------------------------------------------------------------------

resource "azapi_resource" "nsg" {
  type      = "Microsoft.Network/networkSecurityGroups@2024-05-01"
  name      = "${var.name_prefix}-runner-nsg"
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  # Inbound from the internet is denied by default. Also deny inbound from other VNet hosts so a
  # compromised job on one runner VM cannot reach another. Runners only make outbound connections.
  body = {
    properties = {
      securityRules = [{
        name = "deny-vnet-inbound"
        properties = {
          priority                 = 4000
          direction                = "Inbound"
          access                   = "Deny"
          protocol                 = "*"
          sourceAddressPrefix      = "VirtualNetwork"
          sourcePortRange          = "*"
          destinationAddressPrefix = "*"
          destinationPortRange     = "*"
        }
      }]
    }
  }
}

resource "azapi_resource" "vnet" {
  type      = "Microsoft.Network/virtualNetworks@2024-05-01"
  name      = "${var.name_prefix}-vnet"
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  body = {
    properties = {
      addressSpace = { addressPrefixes = [var.address_space] }
      subnets = [
        {
          name = "runners"
          properties = {
            addressPrefix = local.runner_subnet
            # Outbound internet (GitHub, Azure APIs, tool downloads) via Azure default
            # outbound access. This subscription can't create public IPs, so a NAT gateway
            # isn't an option; switch to one if that restriction is lifted.
            defaultOutboundAccess = true
            networkSecurityGroup  = { id = azapi_resource.nsg.id }
          }
        },
        {
          name = "private-endpoints"
          properties = {
            addressPrefix                  = local.pe_subnet
            defaultOutboundAccess          = false
            privateEndpointNetworkPolicies = "Disabled"
          }
        },
      ]
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ---- Private endpoint to Terraform state storage --------------------------------

resource "azapi_resource" "blob_dns_zone" {
  type      = "Microsoft.Network/privateDnsZones@2024-06-01"
  name      = "privatelink.blob.core.windows.net"
  parent_id = local.rg_id
  location  = "global"
  tags      = local.tags
}

resource "azapi_resource" "blob_dns_link" {
  type      = "Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01"
  name      = "${var.name_prefix}-vnet-link"
  parent_id = azapi_resource.blob_dns_zone.id
  location  = "global"
  tags      = local.tags
  body = {
    properties = {
      registrationEnabled = false
      virtualNetwork      = { id = azapi_resource.vnet.id }
    }
  }
}

resource "azapi_resource" "state_pe" {
  type      = "Microsoft.Network/privateEndpoints@2024-05-01"
  name      = "${var.name_prefix}-tfstate-blob-pe"
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  body = {
    properties = {
      subnet = { id = "${azapi_resource.vnet.id}/subnets/private-endpoints" }
      privateLinkServiceConnections = [{
        name = "tfstate-blob"
        properties = {
          privateLinkServiceId = local.storage_account_id
          groupIds             = ["blob"]
        }
      }]
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azapi_resource" "state_pe_dns" {
  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01"
  name      = "default"
  parent_id = azapi_resource.state_pe.id
  body = {
    properties = {
      privateDnsZoneConfigs = [{
        name       = "blob"
        properties = { privateDnsZoneId = azapi_resource.blob_dns_zone.id }
      }]
    }
  }
}

# ---- Runner VMs ----------------------------------------------------------------------

moved {
  from = azapi_resource.ssh_key
  to   = azapi_resource.ssh_key["foundation"]
}
moved {
  from = azapi_resource_action.ssh_keygen
  to   = azapi_resource_action.ssh_keygen["foundation"]
}
moved {
  from = azapi_resource.nic
  to   = azapi_resource.nic["foundation"]
}
moved {
  from = azapi_resource.vm
  to   = azapi_resource.vm["foundation"]
}

# Azure generates the key pair; only the public key is kept. Access is via
# `az vm run-command`, not SSH (no inbound rules, no public IP).
resource "azapi_resource" "ssh_key" {
  for_each = local.runners

  type      = "Microsoft.Compute/sshPublicKeys@2024-07-01"
  name      = each.value.key
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  body      = {}

  lifecycle {
    ignore_changes = [body]
  }
}

resource "azapi_resource_action" "ssh_keygen" {
  for_each = local.runners

  type                   = "Microsoft.Compute/sshPublicKeys@2024-07-01"
  resource_id            = azapi_resource.ssh_key[each.key].id
  action                 = "generateKeyPair"
  method                 = "POST"
  response_export_values = ["publicKey"]
}

resource "azapi_resource" "nic" {
  for_each = local.runners

  type      = "Microsoft.Network/networkInterfaces@2024-05-01"
  name      = each.value.nic
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  body = {
    properties = {
      ipConfigurations = [{
        name = "ipconfig1"
        properties = {
          privateIPAllocationMethod = "Dynamic"
          subnet                    = { id = "${azapi_resource.vnet.id}/subnets/runners" }
        }
      }]
    }
  }
}

resource "azapi_resource" "vm" {
  for_each = local.runners

  type      = "Microsoft.Compute/virtualMachines@2024-07-01"
  name      = each.value.vm
  parent_id = local.rg_id
  location  = var.location
  tags      = local.tags
  body = {
    properties = {
      hardwareProfile = { vmSize = var.vm_size }
      storageProfile = {
        imageReference = {
          publisher = "Canonical"
          offer     = "ubuntu-24_04-lts"
          sku       = "server"
          version   = "latest"
        }
        osDisk = {
          createOption = "FromImage"
          deleteOption = "Delete"
          managedDisk  = { storageAccountType = "StandardSSD_LRS" }
        }
      }
      osProfile = {
        computerName  = each.value.vm
        adminUsername = var.admin_username
        customData    = base64encode(file("${path.module}/cloud-init.yaml"))
        linuxConfiguration = {
          disablePasswordAuthentication = true
          ssh = {
            publicKeys = [{
              path    = "/home/${var.admin_username}/.ssh/authorized_keys"
              keyData = azapi_resource_action.ssh_keygen[each.key].output.publicKey
            }]
          }
        }
      }
      networkProfile = {
        networkInterfaces = [{
          id         = azapi_resource.nic[each.key].id
          properties = { deleteOption = "Delete", primary = true }
        }]
      }
      diagnosticsProfile = { bootDiagnostics = { enabled = true } }
    }
  }

  # customData, the generated key and the OS disk SKU are create-time only (the original VM's disk is
  # Standard_LRS; changing it needs a deallocate).
  lifecycle {
    ignore_changes = [
      body.properties.osProfile,
      body.properties.storageProfile.osDisk.managedDisk,
    ]
    prevent_destroy = true
  }

  depends_on = [azapi_resource.state_pe_dns, azapi_resource.blob_dns_link]
}
