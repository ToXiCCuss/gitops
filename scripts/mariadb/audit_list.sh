#!/bin/bash

# Shows the audit of a database: the tables with audit triggers, the retention and the partitions
# of audit_log with their row counts.
#
# Usage: audit_list.sh <database_name>

if [ -z "$1" ]; then
  echo "Usage: $0 <database_name>"
  exit 1
fi

DB_NAME="$1"

if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "Error: the database name may only contain letters, digits and underscores."
  exit 1
fi

mariadb_cmd() {
  sudo mariadb "$@"
}

echo "------------------------------------------"
echo "Audit of database: $DB_NAME"
echo
echo "Tables with audit triggers:"
mariadb_cmd -t -e "
SELECT EVENT_OBJECT_TABLE AS table_name,
       GROUP_CONCAT(EVENT_MANIPULATION ORDER BY EVENT_MANIPULATION SEPARATOR ', ') AS audited_operations
  FROM information_schema.TRIGGERS
 WHERE TRIGGER_SCHEMA = '$DB_NAME' AND TRIGGER_NAME LIKE '%\_audit'
 GROUP BY EVENT_OBJECT_TABLE
 ORDER BY EVENT_OBJECT_TABLE;"

echo
echo "Maintenance event:"
mariadb_cmd -t -e "
SELECT EVENT_NAME AS event_name, STATUS AS status, EVENT_COMMENT AS retention, LAST_EXECUTED AS last_executed
  FROM information_schema.EVENTS
 WHERE EVENT_SCHEMA = '$DB_NAME' AND EVENT_NAME = 'audit_maintain_partitions';"

echo
echo "Partitions of audit_log:"
mariadb_cmd -t -e "
SELECT PARTITION_NAME AS partition_name, TABLE_ROWS AS approx_rows
  FROM information_schema.PARTITIONS
 WHERE TABLE_SCHEMA = '$DB_NAME' AND TABLE_NAME = 'audit_log'
 ORDER BY PARTITION_ORDINAL_POSITION;"
echo "------------------------------------------"
