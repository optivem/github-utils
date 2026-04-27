#!/bin/bash
# commit.sh
# Commits, pulls, and pushes repos in the academy workspace.
#
# Usage:
#   ./scripts/commit.sh [commit message]
#   ./scripts/commit.sh --repo <repo-name> [commit message]
#   ./scripts/commit.sh --repo <repo-name> --paths "<paths>" [commit message]
#
# Examples:
#   ./scripts/commit.sh                                       # all repos, default message
#   ./scripts/commit.sh "Update settings"                     # all repos, custom message
#   ./scripts/commit.sh --repo eshop-tests                    # single repo, default message
#   ./scripts/commit.sh --repo eshop-tests "Fix"              # single repo, custom message
#   ./scripts/commit.sh --repo shop --paths "src/foo src/bar" "Fix"   # commit only those paths

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

show_usage() {
  cat <<'EOF'
Usage: commit.sh [--repo <name>] [--paths "<paths>"] [commit message]

Commits, pulls, and pushes repos in the academy workspace.

Options:
  --repo <name>      Only operate on the named repo
  --paths "<paths>"  Stage only these space-separated paths (relative to repo root)
                     instead of `git add -A`. Useful for committing one logical
                     scope at a time. Requires --repo.
  -h, --help         Show this help

Examples:
  commit.sh
  commit.sh "Update settings"
  commit.sh --repo shop
  commit.sh --repo shop "Fix bug"
  commit.sh --repo shop --paths "system/monolith/java" "fix(monolith-java): resolve sonar issues"
EOF
}

SINGLE_REPO=""
PATHS=""
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --help|-h)
      show_usage
      exit 0
      ;;
    --repo)
      SINGLE_REPO="${2:-}"
      if [[ -z "$SINGLE_REPO" ]]; then
        echo "Error: --repo requires a repo name" >&2
        show_usage >&2
        exit 1
      fi
      shift 2
      ;;
    --paths)
      PATHS="${2:-}"
      if [[ -z "$PATHS" ]]; then
        echo "Error: --paths requires a path or list of paths" >&2
        show_usage >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Error: unknown flag '$1'" >&2
      show_usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$PATHS" && -z "$SINGLE_REPO" ]]; then
  echo "Error: --paths requires --repo (path semantics are repo-scoped)" >&2
  show_usage >&2
  exit 1
fi

COMMIT_MSG="${1:-"Sync changes"}"
load_workspace_folders

committed=0
synced=0
skipped=0

if [[ -n "$SINGLE_REPO" ]]; then
  echo "============================================"
  echo "  Commit Repo: $SINGLE_REPO"
  if [[ -n "$PATHS" ]]; then
    echo "  Paths: $PATHS"
  fi
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

  if [[ -n "$PATHS" ]]; then
    # Stage only the specified paths
    # shellcheck disable=SC2086
    git -C "$repo" add -- $PATHS
    # Check if anything was actually staged
    if git -C "$repo" diff --cached --quiet; then
      echo "  (no staged changes under: $PATHS)"
    else
      git -C "$repo" diff --cached --name-only | sed 's/^/  /'
      git -C "$repo" commit -m "$COMMIT_MSG

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
      ((committed++)) || true
      echo "  ✓ Committed"
    fi
  else
    status=$(git -C "$repo" status --short)

    if [[ -n "$status" ]]; then
      echo "$status"
      git -C "$repo" add -A
      git -C "$repo" commit -m "$COMMIT_MSG

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
      ((committed++)) || true
      echo "  ✓ Committed"
    fi
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
