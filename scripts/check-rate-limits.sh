#!/bin/bash
# check-rate-limits.sh
# Shows current GitHub API rate limits and when they reset.

set -euo pipefail

echo "=========================================="
echo "  GitHub API Rate Limits"
echo "=========================================="
echo ""

gh api rate_limit --jq '
  .resources | to_entries[] |
  "\(.key):\n  Used:      \(.value.used) / \(.value.limit)\n  Remaining: \(.value.remaining)\n  Resets at: \(.value.reset | todate)\n"
'
