#!/bin/bash
# delete-repos.sh
# Deletes GitHub repos under OWNER, selected by prefix and/or explicit names.
# At least one of --prefix or explicit repo names must be provided.
#
# Usage:
#   ./scripts/delete-repos.sh <owner> --prefix <prefix>
#   ./scripts/delete-repos.sh <owner> repo1 repo2
#   ./scripts/delete-repos.sh <owner> --prefix <prefix> repo1 repo2
#   DRY_RUN=1 ./scripts/delete-repos.sh <owner> --prefix <prefix>
#
# Examples:
#   ./scripts/delete-repos.sh valentinajemuovic --prefix course-tester-
#   ./scripts/delete-repos.sh myorg --prefix temp- specific-repo another-repo
#   DRY_RUN=1 ./scripts/delete-repos.sh myorg --prefix old-

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <owner> [--prefix <prefix>] [repo1 repo2 ...]"
  echo ""
  echo "  --prefix <prefix>   Delete all repos whose names start with prefix"
  echo "  repo1 repo2 ...     Delete specific repos by name"
  echo ""
  echo "Examples:"
  echo "  $0 valentinajemuovic --prefix course-tester-"
  echo "  $0 myorg repo-a repo-b"
  echo "  $0 myorg --prefix temp- specific-repo"
  echo ""
  echo "Environment variables:"
  echo "  DRY_RUN=1   Preview what would be deleted without making changes"
  exit 1
fi

OWNER="$1"
shift

PREFIX=""
EXPLICIT_REPOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    *)
      EXPLICIT_REPOS+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$PREFIX" && ${#EXPLICIT_REPOS[@]} -eq 0 ]]; then
  echo "Error: provide --prefix, explicit repo names, or both."
  exit 1
fi

echo "============================================"
echo "  GitHub Repo Cleanup"
echo "  Owner:  $OWNER"
[[ -n "$PREFIX" ]] && echo "  Prefix: $PREFIX"
[[ ${#EXPLICIT_REPOS[@]} -gt 0 ]] && echo "  Repos:  ${EXPLICIT_REPOS[*]}"
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "  Mode: DRY RUN (no changes will be made)"
fi
echo "============================================"

total_deleted=0

delete_repo() {
  local full_repo="${OWNER}/$1"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "  [DRY RUN] Would delete: $full_repo"
  else
    echo "  Deleting: $full_repo ..."
    wait_for_rate_limit
    gh_api_or_stop -X DELETE "repos/${full_repo}"
    echo "    ✓ Deleted"
    ((total_deleted++)) || true
    sleep "${DELAY_BETWEEN_DELETES}"
  fi
}

# Delete repos matching prefix
if [[ -n "$PREFIX" ]]; then
  page=1
  found_any=0

  while true; do
    wait_for_rate_limit
    gh_api_or_stop "users/${OWNER}/repos?per_page=${PAGE_SIZE}&page=${page}&type=owner" \
      --jq ".[] | select(.name | startswith(\"${PREFIX}\")) | .name"
    repos="$GH_API_OUTPUT"

    [[ -z "$repos" ]] && break
    found_any=1

    while IFS= read -r repo_name; do
      delete_repo "$repo_name"
    done <<< "$repos"

    ((page++))
  done

  [[ "$found_any" -eq 0 ]] && echo "  No repos found matching prefix '${PREFIX}' under ${OWNER}."
fi

# Delete explicitly named repos
for repo_name in "${EXPLICIT_REPOS[@]}"; do
  delete_repo "$repo_name"
done

echo ""
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "✅ Dry run complete. Re-run without DRY_RUN=1 to delete."
else
  echo "✅ Done. Deleted $total_deleted repo(s)."
fi
