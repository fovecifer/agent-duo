#!/usr/bin/env bash
# test/cli/peer-budget.test.sh - peer budget tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

exit "$ADK_FAIL"
