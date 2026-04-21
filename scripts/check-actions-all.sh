#!/bin/bash
# check-actions-all.sh
# Checks the latest GitHub Actions run status for all repos in the academy workspace.
# For each repo, checks the latest run of EVERY workflow and reports failures with error details.
#
# Usage:
#   ./scripts/check-actions-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
ACADEMY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_FILE="$(ls "$ACADEMY_ROOT"/*.code-workspace 2>/dev/null | head -1)"

if [[ -z "$WORKSPACE_FILE" || ! -f "$WORKSPACE_FILE" ]]; then
  echo "Error: no .code-workspace file found in $ACADEMY_ROOT"
  exit 1
fi

WORKSPACE_FILE_WIN="$(cygpath -w "$WORKSPACE_FILE" 2>/dev/null || echo "$WORKSPACE_FILE")"
mapfile -t FOLDERS < <(WS_FILE="$WORKSPACE_FILE_WIN" node -e "
  const ws = JSON.parse(require('fs').readFileSync(process.env.WS_FILE, 'utf-8'));
  ws.folders.forEach(f => console.log(f.path || f.name));
")

total_passing=0
total_failing=0
no_workflows=0
failed_details=()

echo "============================================"
echo "  GitHub Actions Status Check"
echo "============================================"

for folder in "${FOLDERS[@]}"; do
  repo="$ACADEMY_ROOT/$folder"

  if [[ ! -d "$repo/.git" ]]; then
    continue
  fi

  wait_for_rate_limit

  # Get all workflow files to discover workflow names
  workflows=$(cd "$repo" && gh_retry workflow list --all 2>&1) || true

  if [[ -z "$workflows" ]]; then
    ((no_workflows++)) || true
    echo "  ⏭  $folder — no workflows"
    continue
  fi

  repo_passing=0
  repo_failing=0
  repo_in_progress=0
  repo_failures=()
  repo_nwo=$(cd "$repo" && gh_retry repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || repo_nwo=""

  while IFS=$'\t' read -r wf_name wf_state wf_id; do
    [[ -z "$wf_name" ]] && continue

    # Get only the latest run for this specific workflow
    latest_run=$(cd "$repo" && gh_retry run list --workflow "$wf_id" --limit 1 2>&1) || true
    [[ -z "$latest_run" ]] && continue

    IFS=$'\t' read -r _status conclusion title workflow branch trigger run_id duration date <<< "$latest_run"

    if [[ "$_status" == "in_progress" || "$_status" == "queued" ]]; then
      ((repo_in_progress++)) || true
    elif [[ "$conclusion" == "failure" ]]; then
      ((repo_failing++)) || true

      # Get the failed step error (last 5 lines of failed log)
      error_snippet=$(cd "$repo" && gh_retry run view "$run_id" --log-failed 2>&1 | grep "##\[error\]" | tail -3 | sed 's/.*##\[error\]/  /' ) || true
      if [[ -z "$error_snippet" ]]; then
        error_snippet="  (no error details available)"
      fi

      if [[ -n "$repo_nwo" ]]; then
        run_url="https://github.com/$repo_nwo/actions/runs/$run_id"
      else
        run_url=""
      fi

      repo_failures+=("$workflow|$title|$run_id|$run_url|$error_snippet")
    else
      ((repo_passing++)) || true
    fi
  done <<< "$workflows"

  if [[ $repo_failing -gt 0 ]]; then
    ((total_failing++)) || true
    status_parts=()
    [[ $repo_passing -gt 0 ]] && status_parts+=("$repo_passing passing")
    [[ $repo_failing -gt 0 ]] && status_parts+=("$repo_failing failing")
    [[ $repo_in_progress -gt 0 ]] && status_parts+=("$repo_in_progress in progress")
    echo "  ❌ $folder — $(IFS=', '; echo "${status_parts[*]}")"
    for entry in "${repo_failures[@]}"; do
      IFS='|' read -r workflow title run_id run_url error_snippet <<< "$entry"
      failed_details+=("$folder|$workflow|$title|$run_id|$run_url|$error_snippet")
    done
  else
    ((total_passing++)) || true
    if [[ $repo_in_progress -gt 0 ]]; then
      echo "  ✅ $folder — $repo_passing passing, $repo_in_progress in progress"
    else
      echo "  ✅ $folder — $repo_passing passing"
    fi
  fi
done

echo ""
echo "============================================"
echo "  Summary: $total_passing passing, $total_failing failing, $no_workflows no workflows"
echo "============================================"

if [[ ${#failed_details[@]} -gt 0 ]]; then
  echo ""
  echo "Failure details:"
  for entry in "${failed_details[@]}"; do
    IFS='|' read -r repo workflow title run_id run_url error_snippet <<< "$entry"
    echo ""
    echo "  ❌ $repo / $workflow"
    echo "     Commit: $title"
    [[ -n "$run_url" ]] && echo "     Run:    $run_url"
    echo "     Errors:"
    echo "$error_snippet"
  done
fi
