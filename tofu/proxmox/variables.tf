variable "node_name" {
  description = "Name of the Proxmox node the VMs run on."
  type        = string
}

variable "proxmox_ssh_username" {
  description = "SSH user on the Proxmox host (needed for snippets and disk import)."
  type        = string
  default     = "root"
}

variable "image_datastore_id" {
  description = "Datastore for the cloud image. Needs the content type \"Import\"."
  type        = string
  default     = "local"
}

variable "snippet_datastore_id" {
  description = "Datastore for the cloud-init files. Needs the content type \"Snippets\"."
  type        = string
  default     = "local"
}

variable "disk_datastore_id" {
  description = "Datastore for the VM disks and the cloud-init drive."
  type        = string
  default     = "local-lvm"
}

variable "image_url" {
  description = "Cloud image the VMs are created from."
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "network_prefix_length" {
  type    = number
  default = 24
}

variable "network_gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "ssh_public_keys" {
  description = "Public keys that may log in as root (used by Ansible)."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) > 0
    error_message = "At least one SSH public key is required, otherwise nobody can log in to the VMs."
  }
}

variable "gitops_repository_url" {
  description = "Repository that is checked out on every VM."
  type        = string
  default     = "https://github.com/ToXiCCuss/gitops.git"
}

variable "gitops_branch" {
  type    = string
  default = "master"
}

variable "gitops_directory" {
  type    = string
  default = "/root/gitops"
}

variable "vms" {
  description = "The VMs, keyed by hostname."
  type = map(object({
    vm_id            = number
    ip_address       = string
    cores            = optional(number, 2)
    memory_mebibytes = optional(number, 2048)
    disk_gibibytes   = optional(number, 20)
  }))
}
