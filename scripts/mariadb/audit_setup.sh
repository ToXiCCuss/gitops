#!/bin/bash

# Sets up the audit log of one database, or updates it if it exists. Run it once per database,
# then switch the audit on for single tables with audit_enable.sh.
#
# It creates in the database:
#   audit_log                  table, partitioned by month (one partition per month plus p_future)
#   audit_create_triggers      procedure: INSERT/UPDATE/DELETE triggers of one table
#   audit_drop_triggers        procedure: removes them again
#   audit_maintain_partitions  procedure and daily event: adds the partitions of the next months
#                              and drops the ones older than the retention
#
# The audit log lives in the database itself, so db_delete.sh takes it along. It keeps the old and
# new values of every audited row in clear text (also personal data). The roles of db_create.sh can
# change it, because their grants cover the whole database.
#
# Running it again keeps the data of audit_log. The retention is replaced by the given months,
# without months the current value is kept (first run: 6). It counts full months before the
# current one, a retention of 6 keeps the current month and the 6 before it.
#
# p_future (VALUES LESS THAN MAXVALUE) catches every row without a monthly partition, so an
# audited write never fails, even when the event scheduler is off and the partitions are not added.
#
# Usage: audit_setup.sh <database_name> [retention_months]

DEFAULT_RETENTION_MONTHS=6
MAXIMUM_RETENTION_MONTHS=600
EVENT_NAME="audit_maintain_partitions"

DB_NAME="$1"
RETENTION_MONTHS="$2"

if [ -z "$DB_NAME" ]; then
  echo "Usage: $0 <database_name> [retention_months]"
  exit 1
fi

if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "Error: the database name may only contain letters, digits and underscores."
  exit 1
fi

if [ -n "$RETENTION_MONTHS" ] && { [[ ! "$RETENTION_MONTHS" =~ ^[0-9]+$ ]] || [ "$RETENTION_MONTHS" -lt 1 ] || [ "$RETENTION_MONTHS" -gt "$MAXIMUM_RETENTION_MONTHS" ]; }; then
  echo "Error: the retention must be a number of months between 1 and $MAXIMUM_RETENTION_MONTHS."
  exit 1
fi

mariadb_cmd() {
  sudo mariadb "$@"
}

DATABASE_FOUND=$(mariadb_cmd -N -B -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME'")
if [ -z "$DATABASE_FOUND" ]; then
  echo "Error: database $DB_NAME does not exist."
  exit 1
fi

CURRENT_RETENTION_MONTHS=$(mariadb_cmd -N -B -e "SELECT EVENT_COMMENT FROM information_schema.EVENTS WHERE EVENT_SCHEMA = '$DB_NAME' AND EVENT_NAME = '$EVENT_NAME'" | grep -oE '[0-9]+')
RETENTION_MONTHS="${RETENTION_MONTHS:-${CURRENT_RETENTION_MONTHS:-$DEFAULT_RETENTION_MONTHS}}"

echo "------------------------------------------"
echo "Audit log of database: $DB_NAME"
echo "Retention:             $RETENTION_MONTHS months"

mariadb_cmd "$DB_NAME" <<'SQL' || { echo "Error creating the audit log."; exit 1; }
CREATE TABLE IF NOT EXISTS audit_log (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    table_name     VARCHAR(64)     NOT NULL,
    operation_type VARCHAR(6)      NOT NULL,
    record_id      VARCHAR(255),
    old_data       JSON,
    new_data       JSON,
    timestamp      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    user_name      VARCHAR(128)    NOT NULL DEFAULT USER(),
    PRIMARY KEY (id, timestamp),
    INDEX idx_table_record (table_name, record_id),
    INDEX idx_timestamp (timestamp)
)
PARTITION BY RANGE (UNIX_TIMESTAMP(timestamp)) (
    PARTITION p_future VALUES LESS THAN MAXVALUE
);

DROP PROCEDURE IF EXISTS audit_maintain_partitions;
DROP PROCEDURE IF EXISTS audit_create_triggers;
DROP PROCEDURE IF EXISTS audit_drop_triggers;

DELIMITER //

CREATE PROCEDURE audit_maintain_partitions(IN p_retention_months INT)
BEGIN
    DECLARE v_months_ahead INT DEFAULT 3;
    DECLARE v_month_index INT DEFAULT 0;
    DECLARE v_month_start DATE;
    DECLARE v_partition_name VARCHAR(20);
    DECLARE v_oldest_kept BIGINT;

    WHILE v_month_index <= v_months_ahead DO
        SET v_month_start = DATE_ADD(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL v_month_index MONTH);
        SET v_partition_name = CONCAT('p', DATE_FORMAT(v_month_start, '%Y%m'));

        IF NOT EXISTS (SELECT 1 FROM information_schema.PARTITIONS
                       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'audit_log'
                         AND PARTITION_NAME = v_partition_name) THEN
            SET @audit_sql = CONCAT('ALTER TABLE audit_log REORGANIZE PARTITION p_future INTO (',
                'PARTITION ', v_partition_name, ' VALUES LESS THAN (UNIX_TIMESTAMP(''',
                DATE_ADD(v_month_start, INTERVAL 1 MONTH), ''')), ',
                'PARTITION p_future VALUES LESS THAN MAXVALUE)');
            PREPARE audit_stmt FROM @audit_sql;
            EXECUTE audit_stmt;
            DEALLOCATE PREPARE audit_stmt;
        END IF;

        SET v_month_index = v_month_index + 1;
    END WHILE;

    SET v_oldest_kept = UNIX_TIMESTAMP(DATE_SUB(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL p_retention_months MONTH));

    SELECT GROUP_CONCAT(PARTITION_NAME) INTO @audit_old_partitions
      FROM information_schema.PARTITIONS
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'audit_log'
       AND PARTITION_DESCRIPTION REGEXP '^[0-9]+$'
       AND CAST(PARTITION_DESCRIPTION AS UNSIGNED) <= v_oldest_kept;

    IF @audit_old_partitions IS NOT NULL THEN
        SET @audit_sql = CONCAT('ALTER TABLE audit_log DROP PARTITION ', @audit_old_partitions);
        PREPARE audit_stmt FROM @audit_sql;
        EXECUTE audit_stmt;
        DEALLOCATE PREPARE audit_stmt;
    END IF;
END //

CREATE PROCEDURE audit_drop_triggers(IN p_table VARCHAR(64))
BEGIN
    DECLARE v_operation_index INT DEFAULT 0;
    DECLARE v_operation VARCHAR(6);

    WHILE v_operation_index < 3 DO
        SET v_operation = ELT(v_operation_index + 1, 'insert', 'update', 'delete');
        SET @audit_sql = CONCAT('DROP TRIGGER IF EXISTS `', p_table, '_', v_operation, '_audit`');
        PREPARE audit_stmt FROM @audit_sql;
        EXECUTE audit_stmt;
        DEALLOCATE PREPARE audit_stmt;
        SET v_operation_index = v_operation_index + 1;
    END WHILE;
END //

CREATE PROCEDURE audit_create_triggers(IN p_table VARCHAR(64))
BEGIN
    DECLARE v_old_fields TEXT;
    DECLARE v_new_fields TEXT;
    DECLARE v_old_key TEXT;
    DECLARE v_new_key TEXT;
    DECLARE v_insert_into TEXT;

    IF p_table = 'audit_log' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'audit_log cannot be audited';
    END IF;

    IF CHAR_LENGTH(p_table) > 51 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'the table name is too long for the trigger names (51 characters at most)';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.TABLES
                   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table AND TABLE_TYPE = 'BASE TABLE') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'table not found in this database';
    END IF;

    SELECT GROUP_CONCAT(CONCAT(QUOTE(COLUMN_NAME), ', OLD.`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION SEPARATOR ', '),
           GROUP_CONCAT(CONCAT(QUOTE(COLUMN_NAME), ', NEW.`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION SEPARATOR ', ')
      INTO v_old_fields, v_new_fields
      FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table;

    -- The record id is the primary key, several columns joined by "-". Without a primary key it is NULL.
    SELECT IFNULL(CONCAT('CONCAT_WS(''-'', ', GROUP_CONCAT(CONCAT('OLD.`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION SEPARATOR ', '), ')'), 'NULL'),
           IFNULL(CONCAT('CONCAT_WS(''-'', ', GROUP_CONCAT(CONCAT('NEW.`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION SEPARATOR ', '), ')'), 'NULL')
      INTO v_old_key, v_new_key
      FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table AND COLUMN_KEY = 'PRI';

    CALL audit_drop_triggers(p_table);

    SET v_insert_into = CONCAT('INSERT INTO audit_log (table_name, operation_type, record_id, old_data, new_data) VALUES (',
                               QUOTE(p_table), ', ');

    SET @audit_sql = CONCAT('CREATE TRIGGER `', p_table, '_insert_audit` AFTER INSERT ON `', p_table,
                            '` FOR EACH ROW ', v_insert_into,
                            '''INSERT'', ', v_new_key, ', NULL, JSON_OBJECT(', v_new_fields, '))');
    PREPARE audit_stmt FROM @audit_sql;
    EXECUTE audit_stmt;
    DEALLOCATE PREPARE audit_stmt;

    -- An UPDATE that changes no value writes nothing.
    SET @audit_sql = CONCAT('CREATE TRIGGER `', p_table, '_update_audit` AFTER UPDATE ON `', p_table,
                            '` FOR EACH ROW IF NOT (JSON_OBJECT(', v_old_fields, ') <=> JSON_OBJECT(', v_new_fields, ')) THEN ',
                            v_insert_into,
                            '''UPDATE'', ', v_new_key, ', JSON_OBJECT(', v_old_fields, '), JSON_OBJECT(', v_new_fields, ')); END IF');
    PREPARE audit_stmt FROM @audit_sql;
    EXECUTE audit_stmt;
    DEALLOCATE PREPARE audit_stmt;

    SET @audit_sql = CONCAT('CREATE TRIGGER `', p_table, '_delete_audit` AFTER DELETE ON `', p_table,
                            '` FOR EACH ROW ', v_insert_into,
                            '''DELETE'', ', v_old_key, ', JSON_OBJECT(', v_old_fields, '), NULL)');
    PREPARE audit_stmt FROM @audit_sql;
    EXECUTE audit_stmt;
    DEALLOCATE PREPARE audit_stmt;
END //

DELIMITER ;
SQL

mariadb_cmd "$DB_NAME" <<SQL || { echo "Error creating the maintenance event."; exit 1; }
CREATE OR REPLACE EVENT $EVENT_NAME
ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP + INTERVAL 1 DAY
COMMENT 'audit retention months: $RETENTION_MONTHS'
DO CALL audit_maintain_partitions($RETENTION_MONTHS);

CALL audit_maintain_partitions($RETENTION_MONTHS);
SQL

SCHEDULER_STATE=$(mariadb_cmd -N -B -e "SELECT @@event_scheduler")
if [ "$SCHEDULER_STATE" != "ON" ]; then
  echo "Warning: the event scheduler is $SCHEDULER_STATE. The partitions are not added or dropped until it is ON"
  echo "         (event_scheduler = ON in the MariaDB config, set by the Ansible role mariadb)."
fi

echo "Audit log ready. Switch it on per table: audit_enable.sh $DB_NAME <table> [table ...]"
echo "------------------------------------------"
