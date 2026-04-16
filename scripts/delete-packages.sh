#!/bin/bash
# delete-packages.sh
# Deletes all private GitHub packages linked to specified repos.
# Public packages are skipped — they must be made private first via the GitHub UI.
# Private packages are deleted in one call (no need to delete versions individually).
#
# Note: GitHub's API lists packages at the org/user level, not per-repo.
# This script lists all packages by type and filters by repository name.
# The package_type parameter is required by the API.
#
# Usage:
#   ./scripts/delete-packages.sh owner/repo1 owner/repo2   # delete packages from specific repos
#   ./scripts/delete-packages.sh optivem/starter       # single repo
#   DRY_RUN=1 ./scripts/delete-packages.sh owner/repo       # preview what would be deleted
#   BEFORE_DATE=2026-01-01 ./scripts/delete-packages.sh owner/repo  # only delete packages created before this date (exclusive)
#   DELAY=30 ./scripts/delete-packages.sh owner/repo                # wait 30s between deletions (default: 10)
#
# Reference: https://docs.github.com/en/rest/packages/packages

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Each package deletion involves multiple mutating calls:
# 1 PATCH (make private) + N DELETEs (versions) + 1 DELETE (package)
# DELAY_BETWEEN_DELETES=2 keeps us well under the 80 mutating calls/min secondary limit

PACKAGE_TYPES=("npm" "maven" "docker" "nuget" "rubygems" "container")

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <owner/repo> [owner/repo ...]"
  echo "  Example: $0 optivem/starter optivem/eshop-tests"
  echo ""
  echo "Environment variables:"
  echo "  DRY_RUN=1              Preview what would be deleted without making changes"
  echo "  BEFORE_DATE=YYYY-MM-DD Only delete packages created before this date (exclusive)"
  echo "  DELAY=N                Seconds to wait between deletions (default: 10)"
  exit 1
fi

BEFORE_DATE="${BEFORE_DATE:-}"
if [[ -n "${DELAY:-}" ]]; then
  DELAY_BETWEEN_DELETES="$DELAY"
fi

if [[ -n "$BEFORE_DATE" ]]; then
  BEFORE_DATE_EPOCH=$(date -d "$BEFORE_DATE" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$BEFORE_DATE" +%s 2>/dev/null) || {
    echo "Error: invalid BEFORE_DATE format '$BEFORE_DATE'. Use YYYY-MM-DD."
    exit 1
  }
fi

REPOS=("$@")

# Detect whether the owner is an org or a user.
# Returns "orgs" or "users".
get_owner_type() {
  local owner="$1"
  local user_type
  user_type=$(gh api "users/${owner}" --jq '.type' 2>/dev/null || echo "")

  if [[ "$user_type" == "Organization" ]]; then
    echo "orgs"
  else
    echo "users"
  fi
}

# URL-encode package names (e.g. "greeter-java/monolith" -> "greeter-java%2Fmonolith")
url_encode_package() {
  echo "$1" | sed 's/\//%2F/g'
}

delete_packages_for_repo() {
  local full_repo="$1"
  local owner="${full_repo%%/*}"
  local repo_name="${full_repo#*/}"

  echo ""
  echo "========================================="
  echo "  Processing: $full_repo"
  echo "========================================="

  wait_for_rate_limit
  local owner_type
  owner_type=$(get_owner_type "$owner")

  local total_deleted=0
  local total_skipped=0

  # GitHub API requires package_type when listing packages, so we loop through all types
  for package_type in "${PACKAGE_TYPES[@]}"; do
    local page=1

    while true; do
      wait_for_rate_limit

      # List packages of this type, filter by repository name
      local packages
      packages=$(gh api "${owner_type}/${owner}/packages?package_type=${package_type}&per_page=${PAGE_SIZE}&page=${page}" \
        --jq ".[] | select(.repository.name == \"${repo_name}\") | \"\(.name)\t\(.package_type)\t\(.visibility)\t\(.created_at)\"" 2>&1) || {
        # No packages of this type — skip
        break
      }

      if [[ -z "$packages" ]]; then
        break
      fi

      while IFS=$'\t' read -r package_name pkg_type visibility created_at; do
        local encoded_name
        encoded_name=$(url_encode_package "$package_name")
        echo ""
        echo "    Package: $package_name (type: $pkg_type, visibility: $visibility, created: $created_at)"

        if [[ -n "$BEFORE_DATE" ]]; then
          local package_epoch
          package_epoch=$(date -d "$created_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo "0")
          if [[ "$package_epoch" -ge "$BEFORE_DATE_EPOCH" ]]; then
            echo "    Skipping: on or after $BEFORE_DATE"
            continue
          fi
        fi

        # Public packages with many downloads can't be deleted via API.
        # They must be made private first via the GitHub UI:
        # https://github.com/orgs/{owner}/packages/{type}/{package}/settings
        if [[ "$visibility" == "public" ]]; then
          echo "    ⚠️  SKIPPED: Package is public. Make it private first via GitHub UI:"
          echo "       https://github.com/orgs/${owner}/packages/${pkg_type}/${encoded_name}/settings"
          ((total_skipped++)) || true
        elif [[ "$DRY_RUN" == "1" ]]; then
          echo "    [DRY RUN] Would delete package: $package_name"
        else
          # Delete the entire package (including all versions) in one call.
          # Deleting individual versions first can fail for versions that were
          # previously public with >5000 downloads, but deleting the whole
          # package works.
          echo "    Deleting package..."
          wait_for_rate_limit
          gh_api_or_stop -X DELETE "${owner_type}/${owner}/packages/${pkg_type}/${encoded_name}"
          echo "      ✓ Package deleted"

          ((total_deleted++)) || true
          sleep "$DELAY_BETWEEN_DELETES"
        fi
      done <<< "$packages"

      ((page++))
    done
  done

  if [[ "$DRY_RUN" != "1" ]]; then
    if [[ "$total_deleted" -eq 0 && "$total_skipped" -eq 0 ]]; then
      echo "  No packages found."
    else
      echo "  Done. Deleted $total_deleted, skipped $total_skipped (public) packages from $full_repo."
    fi
  fi
}

echo "============================================"
echo "  GitHub Package Cleanup Script"
echo "  Repos: ${REPOS[*]}"
if [[ -n "$BEFORE_DATE" ]]; then
  echo "  Filter: packages created before $BEFORE_DATE (exclusive)"
fi
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  Mode: DRY RUN (no changes will be made)"
fi
echo "============================================"

for repo in "${REPOS[@]}"; do
  delete_packages_for_repo "$repo"

  # Pause between repos to spread out API usage
  if [[ "$repo" != "${REPOS[-1]}" ]]; then
    sleep "$DELAY_BETWEEN_REPOS"
  fi
done

echo ""
echo "✅ All done!"
