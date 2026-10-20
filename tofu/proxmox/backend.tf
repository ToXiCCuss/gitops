# The state lives in the PostgreSQL database tofu_state (created by scripts/postgresql/db_create.sh).
# The connection string comes from backend.hcl (see backend.hcl.example), the password from PGPASSWORD.
terraform {
  backend "pg" {
    schema_name = "public"

    # The owner role of db_create.sh may create objects in the schema public, but not schemas.
    skip_schema_creation = true
  }
}
