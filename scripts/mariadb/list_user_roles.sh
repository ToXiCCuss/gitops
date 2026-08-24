#!/bin/bash

# This script lists all MariaDB users and their assigned roles.

echo "----------------------------------------------------------------------"
echo "MariaDB Users and their Roles:"

# MariaDB stores role assignments in mysql.roles_mapping
sudo mariadb -N -s -e "
SELECT User, Host, 
       (SELECT GROUP_CONCAT(Role) FROM mysql.roles_mapping rm WHERE rm.User = u.User AND rm.Host = u.Host) as roles
FROM mysql.user u
WHERE u.is_role = 'N'
ORDER BY u.User;" | while read -r line; do
    if [[ ! -z "$line" ]]; then
        echo "$line"
    fi
done

echo ""
echo "----------------------------------------------------------------------"
echo "Databases (Schemas):"

sudo mariadb -N -s -e "SHOW DATABASES;" | grep -vE "information_schema|mysql|performance_schema|sys" | while read -r DB; do
    echo "$DB"
done
