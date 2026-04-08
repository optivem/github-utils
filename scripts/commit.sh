#!/bin/bash
# commit.sh
# Commits, pulls, and pushes repos in the academy workspace.
#
# Usage:
#   ./scripts/commit.sh [commit message]
#   ./scripts/commit.sh --repo <repo-name> [commit message]
#
# Examples:
#   ./scripts/commit.sh                           # all repos, default message
#   ./scripts/commit.sh "Update settings"         # all repos, custom message
#   ./scripts/commit.sh --repo eshop-tests        # single repo, default message
#   ./scripts/commit.sh --repo eshop-tests "Fix"  # single repo, custom message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SINGLE_REPO=""
if [[ "${1:-}" == "--repo" ]]; then
  SINGLE_REPO="${2:-}"
  if [[ -z "$SINGLE_REPO" ]]; then
    echo "Error: --repo requires a repo name"
    exit 1
  fi
  shift 2
fi

COMMIT_MSG="${1:-"Sync changes"}"
load_workspace_folders

committed=0
synced=0
skipped=0

if [[ -n "$SINGLE_REPO" ]]; then
  echo "============================================"
  echo "  Commit Repo: $SINGLE_REPO"
  echo "  Message: $COMMIT_MSG"
  echo "============================================"
else
  echo "============================================"
  echo "  Commit All Repos"
  echo "  Message: $COMMIT_MSG"
  echo "============================================"
fi

for folder in "${FOLDERS[@]}"; do
  repo="$ACADEMY_ROOT/$folder"

  # If a single repo was requested, skip all others
  if [[ -n "$SINGLE_REPO" ]]; then
    repo_name="$(basename "$folder")"
    if [[ "$repo_name" != "$SINGLE_REPO" ]]; then
      continue
    fi
  fi

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
