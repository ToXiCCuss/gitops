# The passphrase must not be committed. It is supplied through the environment variable
# TF_ENCRYPTION, which OpenTofu merges with this block (see README.adoc).
terraform {
  encryption {
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
