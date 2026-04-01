#!/bin/bash
# sync.sh
# Pulls and pushes all repos in the academy workspace (no commit).
#
# Usage:
#   ./scripts/sync.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

load_workspace_folders

synced=0
skipped=0

echo "============================================"
echo "  Sync All Repos"
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

  git -C "$repo" pull
  git -C "$repo" push
  ((synced++)) || true
  echo "  ✓ Pulled and pushed"
done

echo ""
echo "============================================"
echo "  Done. $synced synced, $skipped skipped (no remote)."
echo "============================================"
