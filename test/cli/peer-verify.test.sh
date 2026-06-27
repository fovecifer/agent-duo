#!/usr/bin/env bash
# test/cli/peer-verify.test.sh - peer verify tests
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/harness.sh"

exit "$ADK_FAIL"
