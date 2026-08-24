#!/bin/bash

# This script lists all PostgreSQL users and their assigned roles.
# It also shows which roles have access to which databases.

echo "----------------------------------------------------------------------"
echo "PostgreSQL Users and their Roles (Cluster-wide):"

sudo -u postgres psql -t -c "
SELECT 
    r.rolname AS user_name,
    ARRAY(SELECT b.rolname
          FROM pg_auth_members m
          JOIN pg_roles b ON (m.roleid = b.oid)
          WHERE m.member = r.oid) AS member_of
FROM pg_roles r
WHERE r.rolcanlogin = true
ORDER BY r.rolname;" | while read line; do
    if [[ ! -z "$line" ]]; then
        echo "$line"
    fi
done

echo ""
echo "----------------------------------------------------------------------"
echo "Database Access Permissions (CONNECT):"

sudo -u postgres psql -t -c "
SELECT 
    datname, 
    pg_catalog.pg_get_userbyid(datdba) AS owner,
    datacl
FROM pg_database
WHERE datistemplate = false
ORDER BY datname;" | while read line; do
    if [[ ! -z "$line" ]]; then
        echo "$line"
    fi
done

echo ""
echo "----------------------------------------------------------------------"
echo "User Permissions per Database (Membership in DB-specific roles):"

# List all databases
DB_LIST=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';")

for DB in $DB_LIST; do
    echo "Database: $DB"
    sudo -u postgres psql -d "$DB" -t -c "
    SELECT 
        r.rolname AS user_name,
        ARRAY(SELECT b.rolname
              FROM pg_auth_members m
              JOIN pg_roles b ON (m.roleid = b.oid)
              WHERE m.member = r.oid) AS roles
    FROM pg_roles r
    WHERE r.rolcanlogin = true
    AND EXISTS (
        SELECT 1 FROM pg_auth_members m 
        JOIN pg_roles b ON (m.roleid = b.oid)
        WHERE m.member = r.oid AND b.rolname LIKE '$DB%'
    )
    ORDER BY r.rolname;" | while read line; do
        if [[ ! -z "$line" ]]; then
            echo "  $line"
        fi
    done
    echo "----------------------------------------------------------------------"
done

echo "Note: 'datacl' shows the Access Control List of the database."
echo "Format: {user=privileges/grantor,...}"
