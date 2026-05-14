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

`test-pipeline-templates.sh` (and its `common.sh`/`gh-retry.sh` deps) were removed without a port — the script was unused.

Install: `gh extension install optivem/gh-optivem`
