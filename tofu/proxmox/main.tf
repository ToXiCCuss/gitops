resource "proxmox_download_file" "cloud_image" {
  node_name    = var.node_name
  datastore_id = var.image_datastore_id
  content_type = "import"
  url          = var.image_url
  file_name    = "debian-13-genericcloud-amd64.qcow2"
}

module "vm" {
  source   = "./modules/vm"
  for_each = var.vms

  name             = each.key
  vm_id            = each.value.vm_id
  ip_address       = each.value.ip_address
  cores            = each.value.cores
  memory_mebibytes = each.value.memory_mebibytes
  disk_gibibytes   = each.value.disk_gibibytes

  node_name             = var.node_name
  image_file_id         = proxmox_download_file.cloud_image.id
  disk_datastore_id     = var.disk_datastore_id
  snippet_datastore_id  = var.snippet_datastore_id
  network_bridge        = var.network_bridge
  network_prefix_length = var.network_prefix_length
  network_gateway       = var.network_gateway
  dns_servers           = var.dns_servers

  ssh_public_keys       = var.ssh_public_keys
  gitops_repository_url = var.gitops_repository_url
  gitops_branch         = var.gitops_branch
  gitops_directory      = var.gitops_directory
}
