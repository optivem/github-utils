#!/bin/bash
# commit.sh
# Commits, pulls, and pushes all repos in the academy workspace.
#
# Usage:
#   ./scripts/commit.sh [commit message]
#
# Examples:
#   ./scripts/commit.sh
#   ./scripts/commit.sh "Update settings"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACADEMY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_FILE="$(ls "$ACADEMY_ROOT"/*.code-workspace 2>/dev/null | head -1)"
COMMIT_MSG="${1:-"Sync changes"}"

if [[ -z "$WORKSPACE_FILE" || ! -f "$WORKSPACE_FILE" ]]; then
  echo "Error: no .code-workspace file found in $ACADEMY_ROOT"
  exit 1
fi

# Extract folder paths from workspace JSON (pass path via env var to avoid quoting issues)
WORKSPACE_FILE_WIN="$(cygpath -w "$WORKSPACE_FILE" 2>/dev/null || echo "$WORKSPACE_FILE")"
mapfile -t FOLDERS < <(WS_FILE="$WORKSPACE_FILE_WIN" node -e "
  const ws = JSON.parse(require('fs').readFileSync(process.env.WS_FILE, 'utf-8'));
  ws.folders.forEach(f => console.log(f.path || f.name));
")

# Ensure git uses gh for credentials (avoids Windows Credential Manager popups)
gh auth setup-git

committed=0
synced=0
skipped=0

echo "============================================"
echo "  Commit All Repos"
echo "  Message: $COMMIT_MSG"
echo "============================================"

for folder in "${FOLDERS[@]}"; do
  repo="$ACADEMY_ROOT/$folder"

  if [[ ! -d "$repo/.git" ]]; then
    continue
  fi

  # Skip repos with no remote tracking branch
  if ! git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null; then
    ((skipped++)) || true
    continue
  fi

  echo ""
  echo "--- $folder ---"

  status=$(git -C "$repo" status --short)

  if [[ -n "$status" ]]; then
    echo "$status"
    git -C "$repo" add -A
    git -C "$repo" commit -m "$COMMIT_MSG

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
    ((committed++)) || true
    echo "  ✓ Committed"
  fi

  git -C "$repo" pull
  git -C "$repo" push
  ((synced++)) || true
  echo "  ✓ Pulled and pushed"
done

echo ""
echo "============================================"
echo "  Done. $committed committed, $synced synced, $skipped skipped (no remote)."
echo "============================================"
