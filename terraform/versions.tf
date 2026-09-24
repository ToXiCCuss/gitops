terraform {
  required_version = ">= 1.0"

  required_providers {
    netbird = {
      source  = "registry.terraform.io/netbirdio/netbird"
      version = ">= 0.0.10, < 0.1.0" # provider is still pre-1.0, pin narrowly
    }
  }
}
