variable "netbird_token" {
  type        = string
  sensitive   = true
  description = "NetBird Management API Personal Access Token. Never set a default here - pass via NB_PAT env var (recommended, provider reads it natively) or TF_VAR_netbird_token."
  default     = null
}

variable "netbird_management_url" {
  type        = string
  description = "Self-hosted NetBird Management API URL (not the public NetBird Cloud default)."
}
