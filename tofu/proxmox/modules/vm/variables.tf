variable "name" {
  description = "Hostname and VM name."
  type        = string
}

variable "vm_id" {
  type = number
}

variable "ip_address" {
  type = string
}

variable "cores" {
  type = number
}

variable "memory_mebibytes" {
  type = number
}

variable "disk_gibibytes" {
  type = number
}

variable "data_disk_gibibytes" {
  description = "Size of a second disk for data (scsi1), kept apart from the system disk. Null: no data disk."
  type        = number
  default     = null
}

variable "cpu_type" {
  type = string
}

variable "tags" {
  type = list(string)
}

variable "startup_order" {
  description = "Start order on the host (lower starts first). Null: no order."
  type        = number
  default     = null
}

variable "node_name" {
  type = string
}

variable "image_file_id" {
  description = "ID of the downloaded cloud image the disk is imported from."
  type        = string
}

variable "disk_datastore_id" {
  type = string
}

variable "snippet_datastore_id" {
  type = string
}

variable "network_bridge" {
  type = string
}

variable "network_prefix_length" {
  type = number
}

variable "network_gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "ssh_public_keys" {
  type = list(string)
}

variable "gitops_repository_url" {
  type = string
}

variable "gitops_branch" {
  type = string
}

variable "gitops_directory" {
  type = string
}
