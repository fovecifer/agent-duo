#!/usr/bin/env bash
# install.sh — symlink agent-duo commands into ~/.local/bin
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"

if ! command -v tmux >/dev/null; then
  echo "⚠️  tmux not found. Install it first:  brew install tmux" >&2
fi

ln -sf "$REPO_DIR/bin/peer" "$BIN_DIR/peer"
ln -sf "$REPO_DIR/start.sh" "$BIN_DIR/agent-duo-start"
chmod +x "$REPO_DIR/bin/peer" "$REPO_DIR/start.sh"

echo "✅ Installed:"
echo "   $BIN_DIR/peer             -> bin/peer"
echo "   $BIN_DIR/agent-duo-start  -> start.sh"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "⚠️  $BIN_DIR is not on your PATH. Add this to ~/.zshrc:"
    echo '    export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac

echo ""
echo "Next steps:"
echo "  1. Append docs/AGENT-INSTRUCTIONS.md to your project's CLAUDE.md and AGENTS.md"
echo "  2. cd <your-project> && agent-duo-start"
echo "  3. tmux -CC attach -t agents"
