#!/bin/bash
# delete-releases.sh
# Deletes all GitHub releases (and their git tags) from specified repos
# with built-in rate limit handling to avoid hitting GitHub API limits.
#
# Usage:
#   ./scripts/delete-releases.sh org/repo1 org/repo2   # delete releases from specific repos
#   ./scripts/delete-releases.sh optivem/greeter-java   # single repo
#   DRY_RUN=1 ./scripts/delete-releases.sh org/repo     # preview what would be deleted
#   BEFORE_DATE=2026-01-01 ./scripts/delete-releases.sh org/repo  # only delete releases created before this date (exclusive)
#   DELAY=30 ./scripts/delete-releases.sh org/repo                # wait 30s between deletions (default: 10)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Each release deletion = 2 mutating calls (delete release + delete tag)
# DELAY_BETWEEN_DELETES=2 gives ~30 deletions/min = 60 mutating calls/min (under 80 limit)

BEFORE_DATE="${BEFORE_DATE:-}"
if [[ -n "${DELAY:-}" ]]; then
  DELAY_BETWEEN_DELETES="$DELAY"
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <owner/repo> [owner/repo ...]"
  echo "  Example: $0 optivem/greeter-java optivem/greeter-dotnet"
  echo ""
  echo "Environment variables:"
  echo "  DRY_RUN=1              Preview what would be deleted without making changes"
  echo "  BEFORE_DATE=YYYY-MM-DD Only delete releases created before this date (exclusive)"
  echo "  DELAY=N                Seconds to wait between deletions (default: 10)"
  exit 1
fi

if [[ -n "$BEFORE_DATE" ]]; then
  BEFORE_DATE_EPOCH=$(date -d "$BEFORE_DATE" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$BEFORE_DATE" +%s 2>/dev/null) || {
    echo "Error: invalid BEFORE_DATE format '$BEFORE_DATE'. Use YYYY-MM-DD."
    exit 1
  }
fi

REPOS=("$@")

delete_releases_for_repo() {
  local full_repo="$1"

  echo ""
  echo "========================================="
  echo "  Processing: $full_repo"
  echo "========================================="

  # Fetch all releases using REST API pagination
  local page=1
  local total_deleted=0

  while true; do
    wait_for_rate_limit

    gh_api_or_stop "repos/${full_repo}/releases?per_page=${PAGE_SIZE}&page=${page}" \
      --jq '.[] | "\(.id)\t\(.tag_name)\t\(.name)\t\(.created_at)"'
    local releases="$GH_API_OUTPUT"

    if [[ -z "$releases" ]]; then
      if [[ "$page" -eq 1 ]]; then
        echo "  No releases found."
      fi
      break
    fi

    while IFS=$'\t' read -r release_id tag_name release_name created_at; do
      if [[ -n "$BEFORE_DATE" ]]; then
        local release_epoch
        release_epoch=$(date -d "$created_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo "0")
        if [[ "$release_epoch" -ge "$BEFORE_DATE_EPOCH" ]]; then
          echo "  Skipping: $release_name (created: $created_at, on or after $BEFORE_DATE)"
          continue
        fi
      fi

      if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [DRY RUN] Would delete: $release_name (tag: $tag_name, created: $created_at)"
      else
        echo "  Deleting release: $release_name (tag: $tag_name)..."

        # Delete the release
        wait_for_rate_limit
        gh_api_or_stop -X DELETE "repos/${full_repo}/releases/${release_id}"
        echo "    ✓ Release deleted"

        # Delete the associated git tag
        wait_for_rate_limit
        gh_api_or_stop -X DELETE "repos/${full_repo}/git/refs/tags/${tag_name}"
        echo "    ✓ Tag deleted"

        ((total_deleted++)) || true
        sleep "$DELAY_BETWEEN_DELETES"
      fi
    done <<< "$releases"

    ((page++))
  done

  if [[ "$DRY_RUN" != "1" ]]; then
    echo "  Done. Deleted $total_deleted releases from $full_repo."
  fi
}

echo "============================================"
echo "  GitHub Release Cleanup Script"
echo "  Repos: ${REPOS[*]}"
if [[ -n "$BEFORE_DATE" ]]; then
  echo "  Filter: releases created before $BEFORE_DATE (exclusive)"
fi
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  Mode: DRY RUN (no changes will be made)"
fi
echo "============================================"

for repo in "${REPOS[@]}"; do
  delete_releases_for_repo "$repo"

  # Pause between repos to spread out API usage
  if [[ "$repo" != "${REPOS[-1]}" ]]; then
    sleep "$DELAY_BETWEEN_REPOS"
  fi
done

echo ""
echo "✅ All done!"
