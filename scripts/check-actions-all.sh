#!/bin/bash
# check-actions-all.sh
# Checks the latest GitHub Actions run status for all repos in the academy workspace.
#
# Usage:
#   ./scripts/check-actions-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

passing=0
failing=0
no_workflows=0
failed_repos=()

echo "============================================"
echo "  GitHub Actions Status Check"
echo "============================================"

for folder in "${FOLDERS[@]}"; do
  repo="$ACADEMY_ROOT/$folder"

  if [[ ! -d "$repo/.git" ]]; then
    continue
  fi

  runs=$(cd "$repo" && gh run list --limit 5 2>&1) || true

  if [[ -z "$runs" ]]; then
    ((no_workflows++)) || true
    echo "  ⏭  $folder — no workflows"
    continue
  fi

  has_failure=false
  while IFS=$'\t' read -r _completed conclusion title workflow _branch _trigger _id _duration _date; do
    if [[ "$conclusion" == "failure" ]]; then
      has_failure=true
      failed_repos+=("$folder|$workflow|$title")
      break
    fi
  done <<< "$runs"

  if $has_failure; then
    ((failing++)) || true
    echo "  ❌ $folder — FAILING"
  else
    ((passing++)) || true
    echo "  ✅ $folder — passing"
  fi
done

echo ""
echo "============================================"
echo "  Summary: $passing passing, $failing failing, $no_workflows no workflows"
echo "============================================"

if [[ ${#failed_repos[@]} -gt 0 ]]; then
  echo ""
  echo "Failed repos:"
  for entry in "${failed_repos[@]}"; do
    IFS='|' read -r repo workflow title <<< "$entry"
    echo "  ❌ $repo ($workflow): $title"
  done
fi
