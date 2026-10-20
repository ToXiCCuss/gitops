resource "proxmox_virtual_environment_file" "cloud_config" {
  node_name    = var.node_name
  datastore_id = var.snippet_datastore_id
  content_type = "snippets"

  source_raw {
    file_name = "${var.name}-cloud-config.yaml"
    data = templatefile("${path.module}/cloud-config.yaml.tftpl", {
      hostname              = var.name
      ssh_public_keys       = var.ssh_public_keys
      gitops_repository_url = var.gitops_repository_url
      gitops_branch         = var.gitops_branch
      gitops_directory      = var.gitops_directory
    })
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vm_id
  on_boot   = true
  tags      = sort(var.tags)

  # One I/O thread per disk, needs the single controller
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory_mebibytes
  }

  disk {
    datastore_id = var.disk_datastore_id
    import_from  = var.image_file_id
    interface    = "scsi0"
    size         = var.disk_gibibytes
    discard      = "on"
    iothread     = true
  }

  dynamic "disk" {
    for_each = var.data_disk_gibibytes == null ? [] : [var.data_disk_gibibytes]

    content {
      datastore_id = var.disk_datastore_id
      interface    = "scsi1"
      size         = disk.value
      file_format  = "raw"
      discard      = "on"
      iothread     = true
    }
  }

  dynamic "startup" {
    for_each = var.startup_order == null ? [] : [var.startup_order]

    content {
      order = startup.value
    }
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id      = var.disk_datastore_id
    user_data_file_id = proxmox_virtual_environment_file.cloud_config.id

    ip_config {
      ipv4 {
        address = "${var.ip_address}/${var.network_prefix_length}"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
