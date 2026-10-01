#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <database_name> <username> [role1 role2 ...]"
  echo "Common roles: ro (read), rw (readWrite), owner (dbOwner), dbAdmin, userAdmin"
  exit 1
fi

DB_NAME=$1
DB_USER=$2
shift 2
ROLES_RAW=("$@")

if [ ${#ROLES_RAW[@]} -eq 0 ] && [ -t 0 ]; then
    echo "No roles specified. Please select a role for '$DB_USER' on database '$DB_NAME':"
    options=("readWrite (rw)" "read (ro)" "dbOwner (owner)" "dbAdmin" "userAdmin" "Custom...")
    select opt in "${options[@]}"; do
        case $opt in
            "readWrite (rw)") ROLES_RAW=("readWrite"); break ;;
            "read (ro)") ROLES_RAW=("read"); break ;;
            "dbOwner (owner)") ROLES_RAW=("dbOwner"); break ;;
            "dbAdmin") ROLES_RAW=("dbAdmin"); break ;;
            "userAdmin") ROLES_RAW=("userAdmin"); break ;;
            "Custom...")
                read -p "Enter custom role: " custom_role
                ROLES_RAW=("$custom_role")
                break
                ;;
            *)
                if [ -n "$opt" ]; then
                    ROLES_RAW=("$opt")
                    break
                else
                    echo "Invalid selection."
                fi
                ;;
        esac
    done
fi

if [ ${#ROLES_RAW[@]} -eq 0 ]; then
    ROLES_RAW=("readWrite")
fi

ROLES=()
for r in "${ROLES_RAW[@]}"; do
    case $r in
        ro) ROLES+=("read") ;;
        rw) ROLES+=("readWrite") ;;
        owner) ROLES+=("dbOwner") ;;
        *) ROLES+=("$r") ;;
    esac
done

ROLES_JSON=""
for role in "${ROLES[@]}"; do
    if [ -n "$ROLES_JSON" ]; then
        ROLES_JSON="$ROLES_JSON, "
    fi
    ROLES_JSON="$ROLES_JSON { role: \"$role\", db: \"$DB_NAME\" }"
done

DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 30)

echo "------------------------------------------"
echo "Database:  $DB_NAME"
echo "Username:  $DB_USER"
echo "Roles:     ${ROLES[*]}"
echo "Password:  $DB_PASS"

CONFIG_FILE="/etc/mongodb-admin.cred"
AUTH_ARGS=""
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
        AUTH_ARGS="-u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
    fi
fi

mongosh $AUTH_ARGS --quiet <<EOF
use $DB_NAME
db.createUser({
  user: "$DB_USER",
  pwd: "$DB_PASS",
  roles: [ $ROLES_JSON ]
})
EOF

if [ $? -eq 0 ]; then
  echo "User $DB_USER created successfully in database $DB_NAME."
else
  echo "Error creating user."
  exit 1
fi
