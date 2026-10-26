#!/usr/bin/env bash
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
# Idempotent: running it again keeps the data of audit_log and reports what it created or changed.
# The retention is replaced by the given months, without months the current value is kept (first run: 6).
# It counts full months before the current one, a retention of 6 keeps the current month and the 6 before it.
#
# p_future (VALUES LESS THAN MAXVALUE) catches every row without a monthly partition, so an
# audited write never fails, even when the event scheduler is off and the partitions are not added.
#
# Usage: audit_setup.sh [--dry-run] <database_name> [retention_months]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly IDENTIFIER_PATTERN='^[A-Za-z0-9_]+$'
readonly MAX_IDENTIFIER_LENGTH=64
readonly DEFAULT_RETENTION_MONTHS=6
readonly MAXIMUM_RETENTION_MONTHS=600
readonly EVENT_NAME="audit_maintain_partitions"

DB_NAME=""
RETENTION_MONTHS=""
CURRENT_RETENTION_MONTHS=""

usage() {
  log "Usage: $0 [--dry-run] <database_name> [retention_months]"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} >= 1 && ${#POSITIONAL[@]} <= 2)) || usage

  DB_NAME=${POSITIONAL[0]}
  validate_pattern "database name" "$DB_NAME" "$MAX_IDENTIFIER_LENGTH" "$IDENTIFIER_PATTERN"
  if ((${#POSITIONAL[@]} == 2)); then
    [[ ${POSITIONAL[1]} =~ ^[0-9]+$ ]] || die "the retention must be a number of months between 1 and $MAXIMUM_RETENTION_MONTHS"
    RETENTION_MONTHS=$((10#${POSITIONAL[1]}))
    ((RETENTION_MONTHS >= 1 && RETENTION_MONTHS <= MAXIMUM_RETENTION_MONTHS)) ||
      die "the retention must be a number of months between 1 and $MAXIMUM_RETENTION_MONTHS"
  fi
}

# The names are validated against IDENTIFIER_PATTERN, so they can be put into the SQL directly
mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

# apply_sql <outcome> <resource>: runs the SQL from stdin in the database, or only reports it with --dry-run
apply_sql() {
  local outcome=$1 resource=$2
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: $resource (not executed)"
  else
    mariadb_admin "$DB_NAME"
    log "$outcome: $resource"
  fi
}

require_database() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME'")" ]] ||
    die "database $DB_NAME does not exist"
}

# The retention is kept in the comment of the event; no event yet is no retention (grep finds nothing)
resolve_retention() {
  CURRENT_RETENTION_MONTHS=$(mariadb_admin -e "SELECT EVENT_COMMENT FROM information_schema.EVENTS WHERE EVENT_SCHEMA = '$DB_NAME' AND EVENT_NAME = '$EVENT_NAME'" | grep -oE '[0-9]+' || true)
  RETENTION_MONTHS=${RETENTION_MONTHS:-${CURRENT_RETENTION_MONTHS:-$DEFAULT_RETENTION_MONTHS}}
  log "retention: $RETENTION_MONTHS months"
}

ensure_audit_log_table() {
  if [[ -n "$(mariadb_admin -e "SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$DB_NAME' AND TABLE_NAME = 'audit_log'")" ]]; then
    log "unchanged: table audit_log"
  else
    apply_sql created "table audit_log" <<'SQL'
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
SQL
  fi
}

# The procedures are replaced on every run, so a changed script reaches existing databases
apply_audit_procedures() {
  apply_sql applied "procedures audit_maintain_partitions, audit_create_triggers, audit_drop_triggers" <<'SQL'
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
}

# The event is only replaced when it is missing or the retention changed, so its schedule is not restarted
ensure_maintenance_event() {
  local outcome=updated
  [[ -n $CURRENT_RETENTION_MONTHS ]] || outcome=created
  if [[ $CURRENT_RETENTION_MONTHS == "$RETENTION_MONTHS" ]]; then
    log "unchanged: event $EVENT_NAME (retention $RETENTION_MONTHS months)"
  else
    apply_sql "$outcome" "event $EVENT_NAME (retention $RETENTION_MONTHS months)" <<SQL
CREATE OR REPLACE EVENT $EVENT_NAME
ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP + INTERVAL 1 DAY
COMMENT 'audit retention months: $RETENTION_MONTHS'
DO CALL audit_maintain_partitions($RETENTION_MONTHS);
SQL
  fi
}

# Adds the missing partitions and drops the ones past the retention; nothing to do when it is all in place
maintain_partitions() {
  apply_sql applied "partitions of audit_log" <<<"CALL audit_maintain_partitions($RETENTION_MONTHS);"
}

warn_if_scheduler_is_off() {
  local scheduler_state
  scheduler_state=$(mariadb_admin -e "SELECT @@event_scheduler")
  if [[ $scheduler_state != ON ]]; then
    log "Warning: the event scheduler is $scheduler_state. The partitions are not added or dropped until it is ON"
    log "         (event_scheduler = ON in the MariaDB config, set by the Ansible role mariadb)."
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb
  require_database

  resolve_retention
  ensure_audit_log_table
  apply_audit_procedures
  ensure_maintenance_event
  maintain_partitions
  warn_if_scheduler_is_off
  log "Audit log ready. Switch it on per table: audit_enable.sh $DB_NAME <table> [table ...]"
}

main "$@"
