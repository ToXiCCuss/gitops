#!/usr/bin/env bash
# =============================================================================
# gitops-open-pull-requests.sh
# Writes the open pull requests of this repository for the textfile collector of the node_exporter:
#
#   gitops_open_pull_request_created_timestamp_seconds{number,title,author,url}
#                                                  creation time of the pull request, one series per pull request
#
# The Status dashboard shows them (kubernetes/monitoring/kubectl/dashboard-status.yaml). The repository is public,
# so the GitHub API needs no token. Without one it allows 60 requests per hour per IP address, which is why a timer
# fetches the list and not every dashboard refresh. Run by the systemd timer gitops-open-pull-requests.timer
# (Ansible role gitops_deploy). Idempotent: the file is replaced atomically and only when the list changed. When
# the request fails the run fails and the last list stays in place.
#
#   gitops-open-pull-requests.sh <metrics file>
# =============================================================================
set -euo pipefail

readonly PULL_REQUESTS_URL='https://api.github.com/repos/ToXiCCuss/gitops/pulls?state=open&per_page=100'
readonly REQUEST_TIMEOUT_SECONDS=30
# Label values of the Prometheus text format escape backslash, double quote and line feed
readonly METRIC_LINES_FILTER='
  def escaped: gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
  .[] | "gitops_open_pull_request_created_timestamp_seconds{number=\"\(.number)\",title=\"\(.title | escaped)\",author=\"\(.user.login | escaped)\",url=\"\(.html_url | escaped)\"} \(.created_at | fromdateiso8601)"
'

temporary_file=""

log() { echo "$*" >&2; }

cleanup() {
  [[ -z "$temporary_file" ]] || rm -f "$temporary_file"
}

usage() {
  log "Usage: $0 <metrics file>"
  exit 2
}

require_tools() {
  local tool
  for tool in curl jq; do
    command -v "$tool" >/dev/null || {
      log "$tool is missing"
      exit 1
    }
  done
}

fetch_pull_requests() {
  curl --fail --silent --show-error --max-time "$REQUEST_TIMEOUT_SECONDS" \
    --header 'Accept: application/vnd.github+json' "$PULL_REQUESTS_URL"
}

# ensure_metrics_file <metrics file>: moves the temporary file there unless the content is already the same
ensure_metrics_file() {
  if cmp --silent "$temporary_file" "$1"; then
    log "unchanged: $1"
  else
    chmod 0644 "$temporary_file"
    mv "$temporary_file" "$1"
    log "updated: $1"
  fi
}

main() {
  [[ $# -eq 1 ]] || usage
  require_tools
  local metrics_file="$1"
  temporary_file=$(mktemp "$metrics_file.XXXXXX")
  trap cleanup EXIT
  fetch_pull_requests | jq --raw-output "$METRIC_LINES_FILTER" >"$temporary_file"
  ensure_metrics_file "$metrics_file"
}

main "$@"
