#!/usr/bin/env bash
# =============================================================================
# node-pvc-usage.sh
# Writes the disk usage of every local-path volume (PVC) of the k3s node for the textfile collector of the
# node_exporter:
#
#   node_pvc_used_bytes{namespace="...",persistentvolumeclaim="..."}   bytes the volume takes on the disk
#
# The kubelet cannot report this for local-path volumes: they are plain directories, so kubelet_volume_stats_*
# shows the usage of the whole disk for every volume. The directories are named
# pvc-<uid>_<namespace>_<claim name>, which gives the labels. Shown in the dashboard "Volumes"
# (kubernetes/monitoring/kubectl/dashboard-volumes.yaml). Run by the systemd timer node-pvc-usage.timer (Ansible
# role node_exporter). Idempotent: the file is replaced atomically and only holds the state of this moment.
#
#   node-pvc-usage.sh <metrics file> <storage directory>
# =============================================================================
set -euo pipefail

temporary_file=""

log() { echo "$*" >&2; }

cleanup() {
  [[ -z "$temporary_file" ]] || rm -f "$temporary_file"
}

usage() {
  log "Usage: $0 <metrics file> <storage directory>"
  exit 2
}

# directory_size <directory>: bytes on the disk, empty if du could not read it. du exits non-zero when a file
# disappears during the run (a compaction), but still prints the total, so its exit code is not used.
directory_size() {
  local output
  output=$(du --summarize --block-size=1 -- "$1" 2>/dev/null || true)
  echo "${output%%[[:space:]]*}"
}

# write_metric <directory>: one metric line for a volume directory named pvc-<uid>_<namespace>_<claim>
write_metric() {
  local directory="$1" name rest namespace claim size
  name="${directory##*/}"
  rest="${name#*_}"
  namespace="${rest%%_*}"
  claim="${rest#*_}"
  size=$(directory_size "$directory")
  if [[ -n "$size" ]]; then
    printf 'node_pvc_used_bytes{namespace="%s",persistentvolumeclaim="%s"} %s\n' "$namespace" "$claim" "$size"
  else
    log "Could not read the size of $directory"
  fi
}

main() {
  [[ $# -eq 2 ]] || usage
  local metrics_file="$1" storage_directory="$2" directory
  [[ -d "$storage_directory" ]] || {
    log "$storage_directory does not exist"
    exit 1
  }
  temporary_file=$(mktemp "$metrics_file.XXXXXX")
  trap cleanup EXIT
  {
    for directory in "$storage_directory"/pvc-*_*_*; do
      [[ -d "$directory" ]] && write_metric "$directory"
    done
  } >"$temporary_file"
  chmod 0644 "$temporary_file"
  mv "$temporary_file" "$metrics_file"
}

main "$@"
