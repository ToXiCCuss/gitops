# The state lives in the bucket tofu-state of the RustFS S3 on the Docker host (identity tofu-state, docker/rustfs/identities.json).
# The endpoint comes from backend.hcl (see backend.hcl.example), the keys from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
terraform {
  backend "s3" {
    bucket = "tofu-state"
    key    = "proxmox/terraform.tfstate"

    # RustFS is no AWS: a fixed signing region, path-style URLs and no AWS account lookups.
    region                      = "us-east-1"
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true

    # The lock is a file in the bucket (S3 conditional writes), no DynamoDB table.
    use_lockfile = true
  }
}
