#!/bin/bash

SOURCE_DB="fivem"
TARGET_DB="fivem_dev"

echo "[INFO] Creating dump from $SOURCE_DB..."
mariadb-dump --single-transaction --quick --lock-tables=false \
        "$SOURCE_DB" > "dump.sql"

echo "[INFO] Dropping all tables in $TARGET_DB..."
mariadb "$TARGET_DB" -e "
SET FOREIGN_KEY_CHECKS = 0;

SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;')
FROM information_schema.tables
WHERE table_schema = '$TARGET_DB';" | tail -n +2 | \
mariadb "$TARGET_DB" -e "
SET FOREIGN_KEY_CHECKS = 0;
$(cat)"

echo "[INFO] Importing dump into $TARGET_DB..."
mariadb "$TARGET_DB" < dump.sql
rm dump.sql
echo "[INFO] Database copy completed successfully!"
