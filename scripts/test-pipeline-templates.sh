#!/bin/bash
# test-pipeline-templates.sh
# End-to-end pipeline template tester.
#
# Tests all greeter pipeline templates by:
#   1. Making dummy commits to all repos with commit stages (in parallel)
#   2. Waiting for all commit stages to succeed
#   3. For each pipeline repo (in parallel):
#      a. Triggering acceptance stage, waiting for success, reading RC version
#      b. Triggering QA stage with RC version, waiting for success
#      c. Triggering QA signoff (approved), waiting for success
#      d. Triggering production stage, waiting for success
#
# Usage:
#   ./scripts/test-pipeline-templates.sh
#   OWNER=myorg ./scripts/test-pipeline-templates.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

OWNER="${OWNER:-optivem}"

# Commit stage jobs: "repo:path:workflow"
# Each entry triggers one commit stage workflow run.
COMMIT_STAGE_JOBS=(
  "greeter-java:monolith/.pipeline-test:commit-stage-monolith.yml"
  "greeter-dotnet:monolith/.pipeline-test:commit-stage-monolith.yml"
  "greeter-typescript:monolith/.pipeline-test:commit-stage-monolith.yml"
  "greeter-multi-lang:monolith/.pipeline-test:commit-stage-monolith.yml"
  "greeter-multi-comp:backend/.pipeline-test:commit-stage-backend.yml"
  "greeter-multi-comp:frontend/.pipeline-test:commit-stage-frontend.yml"
  "greeter-multi-repo-backend:backend/.pipeline-test:commit-stage-backend.yml"
  "greeter-multi-repo-frontend:frontend/.pipeline-test:commit-stage-frontend.yml"
)

# Pipeline repos to run acceptance → QA → QA signoff → production.
PIPELINE_REPOS=(
  "greeter-java"
  "greeter-dotnet"
  "greeter-typescript"
  "greeter-multi-comp"
  "greeter-multi-lang"
  "greeter-multi-repo"
)

# ── Helpers ───────────────────────────────────────────────────────────────────

log()         { echo "  $*"; }
log_ok()      { echo "  ✓ $*"; }
log_section() { echo ""; echo "════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════"; }

# Push a dummy commit to <repo> at <path> using the GitHub Contents API.
# Prints the resulting commit SHA to stdout.
push_dummy_commit() {
  local repo="$1" path="$2"
  local full_repo="${OWNER}/${repo}"

  local timestamp content existing_sha input_json
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  content=$(printf 'pipeline-test %s\n' "$timestamp" | base64 | tr -d '\n')

  existing_sha=$(gh api "repos/${full_repo}/contents/${path}" --jq '.sha' 2>/dev/null || true)

  if [[ -n "$existing_sha" ]]; then
    input_json=$(printf '{"message":"test: trigger pipeline template test","content":"%s","sha":"%s"}' \
      "$content" "$existing_sha")
  else
    input_json=$(printf '{"message":"test: trigger pipeline template test","content":"%s"}' "$content")
  fi

  wait_for_rate_limit
  echo "$input_json" | gh api "repos/${full_repo}/contents/${path}" -X PUT --input - --jq '.commit.sha'
}

# Find the run ID for the workflow triggered by a specific commit SHA.
# Polls until found (up to 2 minutes).
find_run_for_commit() {
  local repo="$1" workflow="$2" commit_sha="$3"
  local full_repo="${OWNER}/${repo}"
  local run_id="" attempts=0 max_attempts=24

  while [[ -z "$run_id" && "$attempts" -lt "$max_attempts" ]]; do
    sleep 5
    run_id=$(gh run list --repo "$full_repo" --workflow "$workflow" --limit 5 \
      --json databaseId,headSha \
      --jq ".[] | select(.headSha == \"$commit_sha\") | .databaseId" \
      2>/dev/null | head -1 || true)
    ((attempts++)) || true
  done

  if [[ -z "$run_id" ]]; then
    echo "ERROR: run not found for ${repo}/${workflow} @ ${commit_sha}" >&2
    return 1
  fi
  echo "$run_id"
}

# Wait for a workflow run to complete successfully.
wait_for_run() {
  local repo="$1" run_id="$2" label="$3"
  local full_repo="${OWNER}/${repo}"

  log "Waiting for ${label} in ${repo} (run ${run_id})..."
  if ! gh run watch "$run_id" --repo "$full_repo" --exit-status 2>/dev/null; then
    echo "FAILED: ${label} in ${repo} (run ${run_id})" >&2
    echo "  View: https://github.com/${full_repo}/actions/runs/${run_id}" >&2
    return 1
  fi
  log_ok "${label} succeeded in ${repo}"
}

# Trigger a workflow, find its run ID, return it.
# Extra args (e.g. -f version=v1.0.0-rc.1) are forwarded to `gh workflow run`.
trigger_workflow() {
  local repo="$1" workflow="$2"
  shift 2
  local full_repo="${OWNER}/${repo}"

  wait_for_rate_limit
  gh workflow run "$workflow" --repo "$full_repo" "$@"
  sleep 10

  gh run list --repo "$full_repo" --workflow "$workflow" --limit 1 \
    --json databaseId --jq '.[0].databaseId'
}

# Trigger acceptance stage, wait for success, verify the 'run' job ran (not skipped),
# then return the RC version. Retries up to 3 times if the stage is skipped.
run_acceptance_stage() {
  local repo="$1"
  local full_repo="${OWNER}/${repo}"
  local attempt=0 max_attempts=3

  while [[ "$attempt" -lt "$max_attempts" ]]; do
    local before run_id
    before=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    log "[${repo}] Triggering acceptance-stage (attempt $((attempt + 1)))..."
    run_id=$(trigger_workflow "$repo" "acceptance-stage.yml")
    log "[${repo}] Acceptance stage run: ${run_id}"

    if ! gh run watch "$run_id" --repo "$full_repo" --exit-status 2>/dev/null; then
      echo "FAILED: acceptance-stage in ${repo} (run ${run_id})" >&2
      echo "  View: https://github.com/${full_repo}/actions/runs/${run_id}" >&2
      return 1
    fi

    local run_job_conclusion
    run_job_conclusion=$(gh run view "$run_id" --repo "$full_repo" --json jobs \
      --jq '.jobs[] | select(.name == "run") | .conclusion' 2>/dev/null || echo "")

    if [[ "$run_job_conclusion" == "success" ]]; then
      local version
      version=$(gh release list --repo "$full_repo" --json tagName,isPrerelease,createdAt \
        --jq "[.[] | select(.isPrerelease and .createdAt > \"${before}\")] | .[0].tagName" \
        2>/dev/null || echo "")

      if [[ -n "$version" && "$version" != "null" ]]; then
        log_ok "[${repo}] Acceptance stage succeeded — RC: ${version}"
        echo "$version"
        return 0
      fi

      echo "ERROR: acceptance-stage succeeded but no RC release found in ${repo}" >&2
      return 1
    fi

    if [[ "$run_job_conclusion" == "skipped" ]]; then
      log "[${repo}] Acceptance stage skipped (no new images). Retrying in 60s..."
      sleep 60
      ((attempt++)) || true
    else
      echo "ERROR: Unexpected 'run' job conclusion '${run_job_conclusion}' in ${repo}" >&2
      return 1
    fi
  done

  echo "ERROR: Acceptance stage kept being skipped in ${repo} after ${max_attempts} attempts" >&2
  return 1
}

# Run the full pipeline for a repo: acceptance → QA → QA signoff → production.
# Output is written to a temp log file (passed as $2) to avoid interleaving.
run_full_pipeline() {
  local repo="$1"
  local full_repo="${OWNER}/${repo}"

  echo ""
  echo "  ─── Pipeline: ${repo} ───"

  # 1. Acceptance stage
  local version
  version=$(run_acceptance_stage "$repo") || return 1

  # 2. QA stage
  log "[${repo}] Triggering qa-stage (version=${version})..."
  local qa_run_id
  qa_run_id=$(trigger_workflow "$repo" "qa-stage.yml" -f "version=${version}")
  wait_for_run "$repo" "$qa_run_id" "QA Stage" || return 1

  # 3. QA signoff (approved)
  log "[${repo}] Triggering qa-signoff (version=${version}, approved)..."
  local signoff_run_id
  signoff_run_id=$(trigger_workflow "$repo" "qa-signoff.yml" -f "version=${version}" -f "result=approved")
  wait_for_run "$repo" "$signoff_run_id" "QA Signoff" || return 1

  # 4. Production stage
  log "[${repo}] Triggering prod-stage (version=${version})..."
  local prod_run_id
  prod_run_id=$(trigger_workflow "$repo" "prod-stage.yml" -f "version=${version}")
  wait_for_run "$repo" "$prod_run_id" "Production Stage" || return 1

  echo "  ─── ✅ ${repo} — full pipeline passed (RC: ${version}) ───"
}

# ── Phase 1: Parallel dummy commits + wait for commit stages ─────────────────

log_section "Phase 1: Making Dummy Commits (parallel)"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

declare -A COMMIT_PIDS

commit_stage_worker() {
  local spec="$1"
  IFS=':' read -r repo path workflow <<< "$spec"
  local key="${repo}__${workflow%.yml}"

  log "Pushing commit: ${repo} (${path})..."

  local sha
  sha=$(push_dummy_commit "$repo" "$path") || {
    echo "ERROR: push_dummy_commit failed for ${repo}:${path}" >&2
    return 1
  }
  log_ok "Committed ${repo} (${path}): ${sha}"

  local run_id
  run_id=$(find_run_for_commit "$repo" "$workflow" "$sha") || return 1
  log "  Found run ${run_id} for ${repo}/${workflow}"

  wait_for_run "$repo" "$run_id" "Commit Stage (${workflow%.yml})" || return 1
}

for spec in "${COMMIT_STAGE_JOBS[@]}"; do
  IFS=':' read -r repo path workflow <<< "$spec"
  key="${repo}__${workflow%.yml}"
  commit_stage_worker "$spec" > "$TMPDIR_TEST/${key}.log" 2>&1 &
  COMMIT_PIDS["$key"]=$!
done

log "Waiting for all commit stages to complete..."
ALL_COMMITS_OK=true
for key in "${!COMMIT_PIDS[@]}"; do
  if ! wait "${COMMIT_PIDS[$key]}"; then
    echo ""
    echo "  ❌ FAILED: Commit stage for ${key}"
    cat "$TMPDIR_TEST/${key}.log"
    ALL_COMMITS_OK=false
  else
    cat "$TMPDIR_TEST/${key}.log"
  fi
done

if [[ "$ALL_COMMITS_OK" != "true" ]]; then
  echo ""
  echo "════════════════════════════════════════"
  echo "  ❌ One or more commit stages failed. Aborting."
  echo "════════════════════════════════════════"
  exit 1
fi

log_section "Phase 1 Complete: All Commit Stages Passed"

# ── Phase 2: Parallel full pipelines ─────────────────────────────────────────

log_section "Phase 2: Running Full Pipelines (parallel)"

declare -a PIPELINE_PIDS=()

for repo in "${PIPELINE_REPOS[@]}"; do
  run_full_pipeline "$repo" > "$TMPDIR_TEST/pipeline_${repo}.log" 2>&1 &
  PIPELINE_PIDS+=($!)
  log "Started pipeline for ${repo} (PID: $!)"
done

echo ""
log "Waiting for all pipelines to complete..."

ALL_PIPELINES_OK=true
for i in "${!PIPELINE_REPOS[@]}"; do
  repo="${PIPELINE_REPOS[$i]}"
  pid="${PIPELINE_PIDS[$i]}"

  if ! wait "$pid"; then
    echo ""
    echo "  ❌ FAILED: Pipeline for ${repo}"
    cat "$TMPDIR_TEST/pipeline_${repo}.log"
    ALL_PIPELINES_OK=false
  else
    cat "$TMPDIR_TEST/pipeline_${repo}.log"
  fi
done

echo ""
if [[ "$ALL_PIPELINES_OK" == "true" ]]; then
  echo "════════════════════════════════════════"
  echo "  ✅ All pipeline templates passed!"
  echo "════════════════════════════════════════"
else
  echo "════════════════════════════════════════"
  echo "  ❌ Some pipeline templates failed."
  echo "════════════════════════════════════════"
  exit 1
fi
