# github-utils (deprecated)

The scripts in this directory were ported to the `gh optivem` CLI on 2026-05-14.

- `commit.sh` → `gh optivem workspace commit`
- `sync.sh` → `gh optivem workspace sync`
- `check-actions-all.sh` → `gh optivem workspace check-actions`
- `check-rate-limits.sh` → `gh optivem workspace rate-limit`
- `delete-releases.sh` → `gh optivem cleanup releases`
- `delete-packages.sh` → `gh optivem cleanup packages`
- `delete-repos.sh` → `gh optivem cleanup repos`
- `delete-sonar-projects.sh` → `gh optivem cleanup sonar-projects`

Install: `gh extension install optivem/gh-optivem`

## Not yet ported

- `scripts/test-pipeline-templates.sh` — pipeline-templates operational test (327 lines, parallel orchestration). Deferred to a dedicated session. `common.sh` and `gh-retry.sh` are kept solely as its dependencies.
