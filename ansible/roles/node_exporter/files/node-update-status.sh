#!/usr/bin/env bash
# =============================================================================
# node-update-status.sh
# Writes the update state of the host for the textfile collector of the node_exporter:
#
#   node_reboot_required_since_timestamp_seconds   since when a reboot is needed, 0 if none is. That is the time of
#                                                  /var/run/reboot-required, or on Debian (which does not create
#                                                  it) the time the newest installed kernel image arrived when it
#                                                  differs from the running kernel
#   node_pending_updates{type="all|security"}      packages that apt would install or upgrade
#   node_unattended_upgrades_last_run_timestamp_seconds
#                                                  time of the last run of unattended-upgrades, 0 if it never ran
#
# Prometheus alerts on them (kubernetes/monitoring/kubectl/alert-rules-os-updates.yaml). Run by the systemd
# timer node-update-status.timer (Ansible role node_exporter). Idempotent: the file is replaced
# atomically and only holds the state of this moment.
#
#   node-update-status.sh <metrics file>
# =============================================================================
set -euo pipefail

readonly REBOOT_REQUIRED_FILE=/var/run/reboot-required
readonly UNATTENDED_UPGRADES_STAMP=/var/lib/apt/periodic/unattended-upgrades-stamp
readonly SECURITY_PATTERN='security'

temporary_file=""

log() { echo "$*" >&2; }

cleanup() {
  [[ -z "$temporary_file" ]] || rm -f "$temporary_file"
}

usage() {
  log "Usage: $0 <metrics file>"
  exit 2
}

# modification_time <file>: seconds since the epoch, 0 if the file does not exist
modification_time() {
  if [[ -e "$1" ]]; then
    stat --format=%Y "$1"
  else
    echo 0
  fi
}

# reboot_required_since: see the header, 0 if no reboot is needed
reboot_required_since() {
  local newest_image running_version since=0
  if [[ -e "$REBOOT_REQUIRED_FILE" ]]; then
    since=$(modification_time "$REBOOT_REQUIRED_FILE")
  else
    newest_image=$(printf '%s
' /boot/vmlinuz-* | sort --version-sort | tail --lines=1)
    running_version=$(uname --kernel-release)
    if [[ -e "$newest_image" && "${newest_image##*/vmlinuz-}" != "$running_version" ]]; then
      since=$(modification_time "$newest_image")
    fi
  fi
  echo "$since"
}

# simulated_installs: one "Inst ..." line per package that apt would install or upgrade. -s does not change
# anything, NoLocking lets it run while another apt process holds the lock
simulated_installs() {
  apt-get --simulate --option Debug::NoLocking=true dist-upgrade 2>/dev/null | grep '^Inst' || true
}

# security_installs <lines>: the lines of the simulated installs that come from a security archive
security_installs() {
  grep --ignore-case -- "$SECURITY_PATTERN" <<<"$1" || true
}

# count_lines: the number of non-empty lines on stdin
count_lines() {
  grep --count . || true
}

main() {
  [[ $# -eq 1 ]] || usage
  command -v apt-get >/dev/null || {
    log "apt-get is missing"
    exit 1
  }
  local metrics_file="$1" installs pending_all pending_security
  installs=$(simulated_installs)
  pending_all=$(count_lines <<<"$installs")
  pending_security=$(count_lines <<<"$(security_installs "$installs")")
  temporary_file=$(mktemp "$metrics_file.XXXXXX")
  trap cleanup EXIT
  {
    printf 'node_reboot_required_since_timestamp_seconds %s\n' "$(reboot_required_since)"
    printf 'node_pending_updates{type="all"} %s\n' "$pending_all"
    printf 'node_pending_updates{type="security"} %s\n' "$pending_security"
    printf 'node_unattended_upgrades_last_run_timestamp_seconds %s\n' "$(modification_time "$UNATTENDED_UPGRADES_STAMP")"
  } >"$temporary_file"
  chmod 0644 "$temporary_file"
  mv "$temporary_file" "$metrics_file"
}

main "$@"
