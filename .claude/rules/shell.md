---
paths:
  - "**/*.sh"
  - "**/*.bash"
---

# Shell scripts (Bash)

## Idempotency (mandatory)
- Every script is idempotent: a second run with the same arguments changes nothing, reports that nothing changed and exits with `0`. A run that was aborted can simply be started again.
- Check the actual state before every change and act only on a difference: `mkdir -p`, `rm -f`, `ln -sfn`, `grep -qxF "$line" "$file" || echo "$line" >> "$file"`, create resources only if they do not exist yet, update them only if they differ.
- No blind appends, counters, renames or moves that fail or duplicate on the second run. Write files atomically: write to a `mktemp` file in the same folder, then `mv` it over the target.
- Name the desired state, not the steps (`ensure_user`, `ensure_config`), and log per resource whether it was `created`, `updated` or `unchanged`.
- Destructive or remote changes get a `--dry-run` flag that prints the planned changes without making them.

## Structure
- First line `#!/usr/bin/env bash`, then `set -euo pipefail`. Entry point is a function `main "$@"` called at the end of the file; everything else lives in functions with `local` variables.
- Constants `readonly UPPER_SNAKE_CASE`, variables and functions `lower_snake_case`, file names lowercase `kebab-case.sh`.
- Arguments: `usage()` with a short help, unknown or missing arguments print it and exit with `2`. Required tools are checked at the start (`command -v jq >/dev/null || die "jq is missing"`).
- Clean up temporary files with `trap cleanup EXIT`; temporary paths only via `mktemp`.

## Rules
- Quote every expansion (`"$var"`, `"$@"`), use `[[ ]]` instead of `[ ]` and `$(...)` instead of backticks. Never parse `ls` output; iterate globs or use `find -print0`.
- Logs and errors go to stderr (`log() { echo "$*" >&2; }`), data goes to stdout. Errors end with a non-zero exit code, never silently.
- Never print or log secrets; read them from environment variables or files, not from arguments (they show up in the process list).

## Windows checkout
- Line endings must be LF: `.gitattributes` contains `*.sh text eol=lf` (or a global `eol=lf`).
- Make scripts executable in Git: `git update-index --chmod=+x <script>.sh`.

## Check before "done"
- `shellcheck <script>` without findings and `shfmt -d -i 2 <script>` without diff.
- Run the script twice where it is safe locally (temp folder, `--dry-run`): the second run must report only `unchanged`. If there is a `bats` suite, it contains this double-run test.
