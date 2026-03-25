#!/bin/bash
# delete-packages.sh
# Deletes all GitHub packages from specified orgs/users.
# Public packages must be made private before deletion (GitHub requirement).
# Steps per package: list versions -> make private -> delete all versions -> delete package.
#
# Usage:
#   ./scripts/delete-packages.sh owner1 owner2          # delete all packages for owners
#   ./scripts/delete-packages.sh optivem                # single org
#   DRY_RUN=1 ./scripts/delete-packages.sh optivem      # preview what would be deleted
#
# Supported package types: npm, maven, docker, nuget, rubygems, container
# Reference: https://docs.github.com/en/rest/packages/packages

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Each package deletion involves multiple mutating calls:
# 1 PATCH (make private) + N DELETEs (versions) + 1 DELETE (package)
# DELAY_BETWEEN_DELETES=2 keeps us well under the 80 mutating calls/min secondary limit

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <owner> [owner ...]"
  echo "  Example: $0 optivem"
  echo "  Example: $0 optivem my-github-username"
  echo ""
  echo "Environment variables:"
  echo "  DRY_RUN=1   Preview what would be deleted without making changes"
  exit 1
fi

OWNERS=("$@")

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

delete_package_versions() {
  local owner_type="$1"
  local owner="$2"
  local package_type="$3"
  local package_name="$4"

  local page=1

  while true; do
    wait_for_rate_limit

    gh_api_or_stop "${owner_type}/${owner}/packages/${package_type}/${package_name}/versions?per_page=${PAGE_SIZE}&page=${page}" \
      --jq '.[] | "\(.id)\t\(.name)"'
    local versions="$GH_API_OUTPUT"

    if [[ -z "$versions" ]]; then
      break
    fi

    while IFS=$'\t' read -r version_id version_name; do
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "      [DRY RUN] Would delete version: $version_name (id: $version_id)"
      else
        echo "      Deleting version: $version_name..."
        wait_for_rate_limit
        gh_api_or_stop -X DELETE "${owner_type}/${owner}/packages/${package_type}/${package_name}/versions/${version_id}"
        echo "        ✓ Version deleted"
        sleep "$DELAY_BETWEEN_DELETES"
      fi
    done <<< "$versions"

    ((page++))
  done
}

delete_packages_for_owner() {
  local owner="$1"

  echo ""
  echo "========================================="
  echo "  Processing: $owner"
  echo "========================================="

  wait_for_rate_limit
  local owner_type
  owner_type=$(get_owner_type "$owner")
  echo "  Detected owner type: $owner_type"

  local total_deleted=0
  local page=1

  while true; do
    wait_for_rate_limit

    gh_api_or_stop "${owner_type}/${owner}/packages?per_page=${PAGE_SIZE}&page=${page}" \
      --jq '.[] | "\(.name)\t\(.package_type)\t\(.visibility)"'
    local packages="$GH_API_OUTPUT"

    if [[ -z "$packages" ]]; then
      if [[ "$page" -eq 1 ]]; then
        echo "  No packages found."
      fi
      break
    fi

    while IFS=$'\t' read -r package_name package_type visibility; do
      echo ""
      echo "    Package: $package_name (type: $package_type, visibility: $visibility)"

      if [[ "$DRY_RUN" == "1" ]]; then
        echo "    [DRY RUN] Would delete package: $package_name"
        # Still list versions in dry run for visibility
        delete_package_versions "$owner_type" "$owner" "$package_type" "$package_name"
      else
        # Step 1: Make private if public (required before deletion)
        if [[ "$visibility" == "public" ]]; then
          echo "    Making private..."
          wait_for_rate_limit
          gh_api_or_stop -X PATCH "${owner_type}/${owner}/packages/${package_type}/${package_name}" \
            -f visibility=private
          echo "      ✓ Made private"
          sleep "$DELAY_BETWEEN_DELETES"
        fi

        # Step 2: Delete all versions
        echo "    Deleting versions..."
        delete_package_versions "$owner_type" "$owner" "$package_type" "$package_name"

        # Step 3: Delete the package itself
        echo "    Deleting package..."
        wait_for_rate_limit
        gh_api_or_stop -X DELETE "${owner_type}/${owner}/packages/${package_type}/${package_name}"
        echo "      ✓ Package deleted"

        ((total_deleted++))
        sleep "$DELAY_BETWEEN_DELETES"
      fi
    done <<< "$packages"

    ((page++))
  done

  if [[ "$total_deleted" -eq 0 && "$DRY_RUN" != "1" ]]; then
    echo "  No packages found."
  elif [[ "$DRY_RUN" != "1" ]]; then
    echo "  Done. Deleted $total_deleted packages from $owner."
  fi
}

echo "============================================"
echo "  GitHub Package Cleanup Script"
echo "  Owners: ${OWNERS[*]}"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  Mode: DRY RUN (no changes will be made)"
fi
echo "============================================"

for owner in "${OWNERS[@]}"; do
  delete_packages_for_owner "$owner"

  # Pause between owners to spread out API usage
  if [[ "$owner" != "${OWNERS[-1]}" ]]; then
    sleep "$DELAY_BETWEEN_REPOS"
  fi
done

echo ""
echo "✅ All done!"
