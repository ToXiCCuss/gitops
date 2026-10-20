# Endpoint and API token come from PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN.
provider "proxmox" {
  # Uploading snippets and importing disks needs SSH on the Proxmox host.
  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}
