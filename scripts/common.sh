#!/bin/bash
# common.sh
# Shared rate limit and API helper functions for GitHub utils scripts.
#
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/common.sh"

# Rate limit settings based on GitHub API limits:
# - Personal access token: 5,000 requests/hour
# - GITHUB_TOKEN in Actions: 1,000 requests/hour/repo (15,000 for Enterprise Cloud)
# - Secondary limits: max 80 content-modifying requests/minute (POST/PATCH/PUT/DELETE)
# Reference: https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
DELAY_BETWEEN_DELETES="${DELAY_BETWEEN_DELETES:-10}"
DELAY_BETWEEN_REPOS="${DELAY_BETWEEN_REPOS:-10}"
RATE_LIMIT_THRESHOLD="${RATE_LIMIT_THRESHOLD:-50}"
PAGE_SIZE="${PAGE_SIZE:-100}"
DRY_RUN="${DRY_RUN:-0}"

load_workspace_folders() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ACADEMY_ROOT="$(cd "$script_dir/../.." && pwd)"
  local workspace_file
  workspace_file="$(ls "$ACADEMY_ROOT"/*.code-workspace 2>/dev/null | head -1)"

  if [[ -z "$workspace_file" || ! -f "$workspace_file" ]]; then
    echo "Error: no .code-workspace file found in $ACADEMY_ROOT"
    exit 1
  fi

  local workspace_file_win
  workspace_file_win="$(cygpath -w "$workspace_file" 2>/dev/null || echo "$workspace_file")"
  mapfile -t FOLDERS < <(WS_FILE="$workspace_file_win" node -e "
    const ws = JSON.parse(require('fs').readFileSync(process.env.WS_FILE, 'utf-8'));
    ws.folders.forEach(f => console.log(f.path || f.name));
  ")

  gh auth setup-git
}

wait_for_rate_limit() {
  local remaining
  remaining=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo "0")

  if [[ "$remaining" -lt "$RATE_LIMIT_THRESHOLD" ]]; then
    local reset_ts
    reset_ts=$(gh api rate_limit --jq '.resources.core.reset' 2>/dev/null || echo "0")
    local now_ts
    now_ts=$(date +%s)
    local wait_secs=$(( reset_ts - now_ts + 5 ))

    if [[ "$wait_secs" -gt 0 ]]; then
      echo "  ⏳ Rate limit low ($remaining remaining). Waiting ${wait_secs}s for reset..."
      sleep "$wait_secs"
    fi
  fi
}

# Wrapper around gh api that stops the script on any error.
# For rate limit errors, prints when the limit resets.
# Reference: https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
gh_api_or_stop() {
  local exit_code=0
  GH_API_OUTPUT=$(gh api "$@" 2>&1) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    {
      echo ""
      echo "============================================"
      if echo "$GH_API_OUTPUT" | grep -qiE "rate limit|abuse detection|API rate limit exceeded"; then
        local reset_ts
        reset_ts=$(gh api rate_limit --jq '.resources.core.reset' 2>/dev/null || echo "0")
        local reset_time="unknown"
        if [[ "$reset_ts" -gt 0 ]]; then
          reset_time=$(date -d "@$reset_ts" '+%H:%M:%S %Z' 2>/dev/null || date -r "$reset_ts" '+%H:%M:%S %Z' 2>/dev/null || echo "unknown")
        fi
        echo "  STOPPED: GitHub API rate limit exceeded."
        echo "  You can re-run this script after: $reset_time"
      else
        echo "  STOPPED: GitHub API error."
        echo "  $(echo "$GH_API_OUTPUT" | tr -d '\r')"
      fi
      echo "============================================"
    } >&2
    exit 1
  fi
  return 0
}
