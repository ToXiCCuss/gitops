#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
  echo "Usage: $0 <database_name> <new_username> <role_type: ro|rw|owner>"
  exit 1
fi

DB_NAME=$1
NEW_USER="${DB_NAME}_$2"
ROLE_TYPE=$3

case $ROLE_TYPE in
  ro)
    TARGET_ROLE="${DB_NAME}_role_ro"
    ;;
  rw)
    TARGET_ROLE="${DB_NAME}_role_rw"
    ;;
  owner)
    TARGET_ROLE="${DB_NAME}_role_owner"
    ;;
  *)
    echo "Error: Invalid role type. Use 'ro', 'rw', or 'owner'."
    exit 1
    ;;
esac

USER_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 30)

echo "------------------------------------------"
echo "Creating User: $NEW_USER"
echo "Assigning Role: $TARGET_ROLE"
echo "Password:      $USER_PASS"

sudo -u postgres psql -d "$DB_NAME" <<EOF
  CREATE USER "$NEW_USER" WITH PASSWORD '$USER_PASS';

  GRANT "$TARGET_ROLE" TO "$NEW_USER";

  -- Ensure roles have access to existing objects in public schema
  GRANT USAGE ON SCHEMA public TO "${DB_NAME}_role_ro", "${DB_NAME}_role_rw", "${DB_NAME}_role_owner";
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO "${DB_NAME}_role_ro";
  GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO "${DB_NAME}_role_ro";
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${DB_NAME}_role_rw";
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "${DB_NAME}_role_rw";
  GRANT ALL ON ALL TABLES IN SCHEMA public TO "${DB_NAME}_role_owner";
  GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO "${DB_NAME}_role_owner";

  -- If this user creates tables in the future, ensure the roles have access
  ALTER DEFAULT PRIVILEGES FOR ROLE "$NEW_USER" GRANT SELECT ON TABLES TO "${DB_NAME}_role_ro";
  ALTER DEFAULT PRIVILEGES FOR ROLE "$NEW_USER" GRANT SELECT ON SEQUENCES TO "${DB_NAME}_role_ro";
  
  ALTER DEFAULT PRIVILEGES FOR ROLE "$NEW_USER" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${DB_NAME}_role_rw";
  ALTER DEFAULT PRIVILEGES FOR ROLE "$NEW_USER" GRANT USAGE, SELECT ON SEQUENCES TO "${DB_NAME}_role_rw";

  -- If this is an owner user, also allow them to grant permissions to others
  ALTER DEFAULT PRIVILEGES FOR ROLE "$NEW_USER" GRANT ALL ON TABLES TO "${DB_NAME}_role_owner";
  ALTER DEFAULT PRIVILEGES FOR ROLE "$NEW_USER" GRANT ALL ON SEQUENCES TO "${DB_NAME}_role_owner";
EOF

if [ $? -eq 0 ]; then
  echo "User '$NEW_USER' created and assigned to '$TARGET_ROLE'."
  echo "MAKE SURE TO SAVE THE PASSWORD: $USER_PASS"
else
  echo "Error creating user."
fi
echo "------------------------------------------"
