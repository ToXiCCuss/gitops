# One entry per VM, the name is the hostname.
# Optional: cores (2), memory_mebibytes (2048), disk_gibibytes (20, the system disk), cpu_type ("x86-64-v2-AES"), tags,
# startup_order (lower starts first), data_disk_gibibytes (a second disk for the data, not created without it) and
# gateway / network_prefix_length of the VM (default: the values of terraform.tfvars, e.g. for routed additional IPs).
# The data disk is formatted and mounted by Ansible, not by cloud-init.
vms = {
  # Planned VMs for the dedicated server (adjust the sizes to the real databases and fill in the IPs)
  #
  # postgres01 = {
  #   vm_id               = 201
  #   ip_address          = "<ip>"
  #   cores               = 4
  #   memory_mebibytes    = 24576
  #   data_disk_gibibytes = 200
  #   cpu_type            = "host"
  #   tags                = ["database", "postgresql"]
  #   startup_order       = 1
  # }
  # mariadb01 = {
  #   vm_id               = 202
  #   ip_address          = "<ip>"
  #   cores               = 4
  #   memory_mebibytes    = 16384
  #   data_disk_gibibytes = 100
  #   cpu_type            = "host"
  #   tags                = ["database", "mariadb"]
  #   startup_order       = 1
  # }
  # mongodb01 = {
  #   vm_id               = 203
  #   ip_address          = "<ip>"
  #   cores               = 4
  #   memory_mebibytes    = 16384
  #   data_disk_gibibytes = 100
  #   cpu_type            = "host"
  #   tags                = ["database", "mongodb"]
  #   startup_order       = 1
  # }
  # games01 = {
  #   vm_id               = 204
  #   ip_address          = "<ip>"
  #   cores               = 8
  #   memory_mebibytes    = 49152
  #   data_disk_gibibytes = 300
  #   cpu_type            = "host"
  #   tags                = ["games", "pelican"]
  #   startup_order       = 2
  # }
}
