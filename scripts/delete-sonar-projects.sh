#!/bin/bash
# delete-sonar-projects.sh
# Deletes SonarCloud projects under an organization, selected by prefix and/or explicit keys.
# At least one of --prefix or explicit project keys must be provided.
# Requires SONAR_TOKEN environment variable to be set.
#
# Usage:
#   ./scripts/delete-sonar-projects.sh <organization> --prefix <prefix>
#   ./scripts/delete-sonar-projects.sh <organization> project-key1 project-key2
#   ./scripts/delete-sonar-projects.sh <organization> --prefix <prefix> project-key1
#   DRY_RUN=1 ./scripts/delete-sonar-projects.sh <organization> --prefix <prefix>
#
# Examples:
#   ./scripts/delete-sonar-projects.sh myorg --prefix myorg_course-tester-
#   ./scripts/delete-sonar-projects.sh myorg --prefix myorg_temp- myorg_specific-project
#   DRY_RUN=1 ./scripts/delete-sonar-projects.sh myorg --prefix myorg_old-

set -euo pipefail

trap 'echo ""; echo "  ❌ Unexpected error on line $LINENO (exit code $?)" >&2' ERR

SONAR_API_URL="${SONAR_API_URL:-https://sonarcloud.io/api}"
DELAY_BETWEEN_DELETES="${DELAY_BETWEEN_DELETES:-1}"
PAGE_SIZE="${PAGE_SIZE:-100}"
DRY_RUN="${DRY_RUN:-0}"

if [[ -z "${SONAR_TOKEN:-}" ]]; then
  echo "Error: SONAR_TOKEN environment variable is not set."
  echo "Generate a token at https://sonarcloud.io/account/security"
  exit 1
fi

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <organization> [--prefix <prefix>] [project-key1 project-key2 ...]"
  echo ""
  echo "  --prefix <prefix>         Delete all projects whose keys start with prefix"
  echo "  project-key1 ...          Delete specific projects by key"
  echo ""
  echo "Examples:"
  echo "  $0 myorg --prefix myorg_course-tester-"
  echo "  $0 myorg myorg_repo-a myorg_repo-b"
  echo "  $0 myorg --prefix myorg_temp- myorg_specific-project"
  echo ""
  echo "Environment variables:"
  echo "  SONAR_TOKEN        (required) SonarCloud API token"
  echo "  SONAR_API_URL      API base URL (default: https://sonarcloud.io/api)"
  echo "  DRY_RUN=1          Preview what would be deleted without making changes"
  exit 1
fi

ORGANIZATION="$1"
shift

PREFIX=""
EXPLICIT_PROJECTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    *)
      EXPLICIT_PROJECTS+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$PREFIX" && ${#EXPLICIT_PROJECTS[@]} -eq 0 ]]; then
  echo "Error: provide --prefix, explicit project keys, or both."
  exit 1
fi

echo "============================================"
echo "  SonarCloud Project Cleanup"
echo "  Organization: $ORGANIZATION"
[[ -n "$PREFIX" ]] && echo "  Prefix:       $PREFIX"
[[ ${#EXPLICIT_PROJECTS[@]} -gt 0 ]] && echo "  Projects:     ${EXPLICIT_PROJECTS[*]}"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  Mode: DRY RUN (no changes will be made)"
fi
echo "============================================"

total_deleted=0

sonar_api() {
  local method="$1"
  local endpoint="$2"
  shift 2
  local http_code body

  local response
  response=$(curl -s -w "\n%{http_code}" \
    -X "$method" \
    -H "Authorization: Bearer ${SONAR_TOKEN}" \
    "${SONAR_API_URL}/${endpoint}" \
    "$@")

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo ""
    echo "============================================" >&2
    echo "  STOPPED: SonarCloud API error (HTTP $http_code)." >&2
    echo "  $body" >&2
    echo "============================================" >&2
    exit 1
  fi

  SONAR_API_OUTPUT="$body"
}

delete_project() {
  local project_key="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [DRY RUN] Would delete: $project_key"
  else
    echo "  Deleting: $project_key ..."
    sonar_api POST "projects/delete" -d "project=${project_key}"
    echo "    ✓ Deleted"
    ((total_deleted++)) || true
    sleep "$DELAY_BETWEEN_DELETES"
  fi
}

# Delete projects matching prefix
if [[ -n "$PREFIX" ]]; then
  page=1
  found_any=0

  while true; do
    sonar_api GET "projects/search?organization=${ORGANIZATION}&ps=${PAGE_SIZE}&p=${page}"

    project_keys=$(echo "$SONAR_API_OUTPUT" | jq -r ".components[] | select(.key | startswith(\"${PREFIX}\")) | .key")

    if [[ -z "$project_keys" ]]; then
      # Check if we've exhausted all pages
      total_results=$(echo "$SONAR_API_OUTPUT" | jq -r '.paging.total')
      max_page=$(( (total_results + PAGE_SIZE - 1) / PAGE_SIZE ))
      [[ "$page" -ge "$max_page" ]] && break
      ((page++))
      continue
    fi

    found_any=1

    while IFS= read -r project_key; do
      delete_project "$project_key"
    done <<< "$project_keys"

    ((page++))
  done

  [[ "$found_any" -eq 0 ]] && echo "  No projects found matching prefix '${PREFIX}' under ${ORGANIZATION}."
fi

# Delete explicitly named projects
for project_key in "${EXPLICIT_PROJECTS[@]}"; do
  delete_project "$project_key"
done

echo ""
if [[ "$DRY_RUN" == "1" ]]; then
  echo "✅ Dry run complete. Re-run without DRY_RUN=1 to delete."
else
  echo "✅ Done. Deleted $total_deleted project(s)."
fi
