#!/bin/bash
# delete-releases.sh
# Deletes all GitHub releases (and their git tags) from specified repos
# with built-in rate limit handling to avoid hitting GitHub API limits.
#
# Usage:
#   ./scripts/delete-releases.sh                  # delete all releases from all greeter repos
#   ./scripts/delete-releases.sh greeter-java     # delete releases from a single repo
#   DRY_RUN=1 ./scripts/delete-releases.sh        # preview what would be deleted

set -euo pipefail

ORG="optivem"
DELAY_BETWEEN_DELETES=2    # seconds between each delete call
DELAY_BETWEEN_REPOS=5      # seconds between repos
RATE_LIMIT_THRESHOLD=50    # pause when remaining calls drop below this
PAGE_SIZE=100               # releases to fetch per page

ALL_REPOS=(
  greeter
  greeter-dotnet
  greeter-java
  greeter-multi-comp
  greeter-multi-lang
  greeter-multi-repo
  greeter-multi-repo-backend
  greeter-multi-repo-frontend
  greeter-typescript
)

DRY_RUN="${DRY_RUN:-0}"

# Use repos from args, or default to all
if [[ $# -gt 0 ]]; then
  REPOS=("$@")
else
  REPOS=("${ALL_REPOS[@]}")
fi

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

delete_releases_for_repo() {
  local repo="$1"
  local full_repo="${ORG}/${repo}"

  echo ""
  echo "========================================="
  echo "  Processing: $full_repo"
  echo "========================================="

  # Fetch all releases using REST API pagination
  local page=1
  local total_deleted=0

  while true; do
    wait_for_rate_limit

    local releases
    releases=$(gh api "repos/${full_repo}/releases?per_page=${PAGE_SIZE}&page=${page}" \
      --jq '.[] | "\(.id)\t\(.tag_name)\t\(.name)"' 2>&1) || {
      echo "  ⚠️  Failed to list releases for $full_repo: $releases"
      return 1
    }

    if [[ -z "$releases" ]]; then
      if [[ "$page" -eq 1 ]]; then
        echo "  No releases found."
      fi
      break
    fi

    while IFS=$'\t' read -r release_id tag_name release_name; do
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [DRY RUN] Would delete: $release_name (tag: $tag_name, id: $release_id)"
      else
        echo "  Deleting release: $release_name (tag: $tag_name)..."

        # Delete the release
        wait_for_rate_limit
        gh api -X DELETE "repos/${full_repo}/releases/${release_id}" 2>/dev/null && \
          echo "    ✓ Release deleted" || \
          echo "    ✗ Failed to delete release"

        # Delete the associated git tag
        wait_for_rate_limit
        gh api -X DELETE "repos/${full_repo}/git/refs/tags/${tag_name}" 2>/dev/null && \
          echo "    ✓ Tag deleted" || \
          echo "    ✗ Tag not found or already deleted"

        ((total_deleted++))
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
