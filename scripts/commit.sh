#!/bin/bash
# commit.sh
# Commits, pulls, and pushes repos in the academy workspace.
#
# Usage:
#   ./scripts/commit.sh "<commit message>"
#   ./scripts/commit.sh --repo <repo-name> "<commit message>"
#   ./scripts/commit.sh --repo <repo-name> --paths "<paths>" "<commit message>"
#   ./scripts/commit.sh --yes "<commit message>"             # skip interactive y/N prompt
#
# A commit message is required when any iterated repo has dirty changes.
# By default the script prints `git status` for each dirty repo and asks
# for y/N confirmation from /dev/tty before staging. Pass --yes for
# unattended invocations.
#
# `--yes` refuses to stage untracked files unless `--include-untracked` is
# also passed. Background: a Claude harness once dropped a stray log file
# at the repo root, `commit.sh --yes` ran `git add -A`, and the junk landed
# on origin/main before anyone reviewed it. Interactive callers see the
# `??` line in the status output and decline at the y/N prompt; scripted
# callers have no such review point, so untracked files are an opt-in.
#
# Examples:
#   ./scripts/commit.sh "Update settings"                     # all repos, interactive
#   ./scripts/commit.sh --repo eshop-tests "Fix"              # single repo, interactive
#   ./scripts/commit.sh --repo shop --paths "src/foo" "Fix"   # commit only those paths
#   ./scripts/commit.sh --yes "Sync .claude settings"         # scripted, no prompt
#   ./scripts/commit.sh --yes --include-untracked "Add file"  # scripted + new files OK

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

show_usage() {
  cat <<'EOF'
Usage: commit.sh [--repo <name>] [--paths "<paths>"] [--yes] [--include-untracked] "<commit message>"

Commits, pulls, and pushes repos in the academy workspace.

Options:
  --repo <name>         Only operate on the named repo
  --paths "<paths>"     Stage only these space-separated paths (relative to repo root)
                        instead of `git add -A`. Useful for committing one logical
                        scope at a time. Requires --repo.
  --yes                 Skip the per-repo y/N confirmation prompt. Required when
                        stdin is not a TTY (scripted invocation). Refuses to stage
                        untracked files unless --include-untracked is also passed.
  --include-untracked   Allow `--yes` to stage untracked files (`??` entries in
                        git status). Use when the scripted commit is intentionally
                        adding new files. No effect outside `--yes` mode (interactive
                        callers see and confirm the file list at the y/N prompt).
  -h, --help            Show this help

A commit message is required if any iterated repo has dirty changes.

Examples:
  commit.sh "Update settings"
  commit.sh --repo shop "Fix bug"
  commit.sh --repo shop --paths "system/monolith/java" "fix(monolith-java): resolve sonar issues"
  commit.sh --yes "Sync .claude settings"
  commit.sh --yes --include-untracked "Add new test file"
EOF
}

SINGLE_REPO=""
PATHS=""
ASSUME_YES=0
INCLUDE_UNTRACKED=0
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
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --include-untracked)
      INCLUDE_UNTRACKED=1
      shift
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

COMMIT_MSG="${1:-}"
load_workspace_folders

# Refuse to commit anything when no message was supplied. The previous
# default of "Sync changes" produced commits that were visually
# indistinguishable from each other in `git log`, which masked the
# accidental rehearsal-branch leak in d325a797. Forcing a real message
# means an accidental commit carries a mismatched message that's
# obvious in history and push notifications.
require_commit_msg() {
  if [[ -z "$COMMIT_MSG" ]]; then
    echo "Error: commit message is required (no default)." >&2
    echo "       Pass it as the last positional argument, e.g.:" >&2
    echo "         commit.sh \"<message>\"" >&2
    echo "         commit.sh --repo shop \"<message>\"" >&2
    exit 1
  fi
}

confirm_commit() {
  local repo_label="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    echo "Error: stdin is not a TTY and --yes was not set; refusing to commit unattended." >&2
    echo "       Re-run with --yes if this is a scripted invocation." >&2
    exit 1
  fi
  local reply=""
  read -r -p "Commit these changes to $repo_label? [y/N] " reply </dev/tty
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

committed=0
synced=0
skipped=0

if [[ -n "$SINGLE_REPO" ]]; then
  echo "============================================"
  echo "  Commit Repo: $SINGLE_REPO"
  if [[ -n "$PATHS" ]]; then
    echo "  Paths: $PATHS"
  fi
  echo "  Message: ${COMMIT_MSG:-<none — will fail if dirty>}"
  echo "============================================"
else
  echo "============================================"
  echo "  Commit All Repos"
  echo "  Message: ${COMMIT_MSG:-<none — will fail if dirty>}"
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
      require_commit_msg
      git -C "$repo" diff --cached --name-only | sed 's/^/  /'
      if confirm_commit "$folder"; then
        git -C "$repo" commit -m "$COMMIT_MSG

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
        ((committed++)) || true
        echo "  ✓ Committed"
      else
        # Unstage anything we just added so the working tree is restored
        git -C "$repo" reset --quiet -- $PATHS
        echo "  ✗ Skipped (unstaged)"
      fi
    fi
  else
    status=$(git -C "$repo" status --short)

    if [[ -n "$status" ]]; then
      require_commit_msg
      echo "$status"
      # In --yes mode there's no interactive review, so we refuse to stage
      # untracked files unless --include-untracked is explicitly passed.
      # See the script header for the rationale (stray-file incident).
      if [[ "$ASSUME_YES" -eq 1 && "$INCLUDE_UNTRACKED" -eq 0 ]]; then
        untracked=$(echo "$status" | grep '^??' || true)
        if [[ -n "$untracked" ]]; then
          echo "Error: --yes refuses to stage untracked files. Either clean them up," >&2
          echo "       commit them via --paths, or pass --include-untracked to opt in." >&2
          echo "       Untracked entries:" >&2
          echo "$untracked" | sed 's/^/         /' >&2
          exit 1
        fi
      fi
      if confirm_commit "$folder"; then
        git -C "$repo" add -A
        git -C "$repo" commit -m "$COMMIT_MSG

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
        ((committed++)) || true
        echo "  ✓ Committed"
      else
        echo "  ✗ Skipped"
      fi
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
