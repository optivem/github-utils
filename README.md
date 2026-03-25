# GitHub Utils

A collection of utility scripts for managing GitHub repositories.

## Prerequisites

- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated
- Bash (Git Bash on Windows, or native on macOS/Linux)

## Scripts

### delete-releases.sh

Bulk deletes GitHub releases and their associated git tags from one or more repositories. Includes automatic rate limit detection — pauses and waits when API limits are low.

**Usage:**

```bash
# Delete all releases from specific repos
./scripts/delete-releases.sh owner/repo1 owner/repo2

# Single repo
./scripts/delete-releases.sh optivem/greeter-java

# Preview what would be deleted (no changes made)
DRY_RUN=1 ./scripts/delete-releases.sh optivem/greeter-java

# Multiple repos
./scripts/delete-releases.sh optivem/greeter-java optivem/greeter-dotnet optivem/greeter-typescript
```

The `owner` can be a GitHub organization or a personal user account.

### delete-packages.sh

Bulk deletes GitHub packages from one or more repositories. Handles the GitHub requirement of making public packages private before deletion.

**Usage:**

```bash
# Delete all packages from specific repos
./scripts/delete-packages.sh owner/repo1 owner/repo2

# Single repo
./scripts/delete-packages.sh optivem/eshop

# Preview what would be deleted (no changes made)
DRY_RUN=1 ./scripts/delete-packages.sh optivem/eshop
```

The `owner` can be a GitHub organization or a personal user account.
