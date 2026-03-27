#!/bin/bash
# sync-all.sh
# Runs the Claude settings sync script to distribute settings across all workspace repos.
#
# Usage:
#   ./scripts/sync-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACADEMY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYNC_SCRIPT="$ACADEMY_ROOT/claude/scripts/sync-claude-settings.js"

if [[ ! -f "$SYNC_SCRIPT" ]]; then
  echo "Error: sync script not found at $SYNC_SCRIPT"
  exit 1
fi

echo "============================================"
echo "  Sync Claude Settings"
echo "============================================"
node "$SYNC_SCRIPT"
echo "============================================"
