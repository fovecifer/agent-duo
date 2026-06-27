#!/usr/bin/env bash
# test/e2e/journey-codex.test.sh - gated real Codex/tmux journey skeleton.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/assert.sh"

skip() { printf 'skip %s: %s\n' "journey-codex" "$1"; exit 0; }

[[ "${AGENT_DUO_E2E_CODEX:-}" == "1" ]] || skip "set AGENT_DUO_E2E_CODEX=1 to run (real codex journey)"
command -v codex >/dev/null 2>&1 || skip "codex CLI not installed"
command -v tmux  >/dev/null 2>&1 || skip "tmux not installed"
[[ -f "$HOME/.codex/auth.json" ]] || skip "no ~/.codex/auth.json"

echo "journey-codex: gated skeleton ok"
