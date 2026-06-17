#!/usr/bin/env bash
# install.sh — symlink agent-duo commands into ~/.local/bin
set -euo pipefail

FORCE=0
for arg in "$@"; do
  case "$arg" in
    -f|--force) FORCE=1 ;;
    -h|--help)
      echo "Usage: ./install.sh [--force]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: ./install.sh [--force]" >&2
      exit 1
      ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"

if ! command -v tmux >/dev/null; then
  echo "⚠️  tmux not found. Install it first:  brew install tmux" >&2
fi

if ! command -v jq >/dev/null; then
  echo "⚠️  jq not found. Install it first:  brew install jq" >&2
fi

link_command() {
  local src="$1" dest="$2" current=""
  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ -L "$dest" ]]; then
      current="$(readlink "$dest")"
      if [[ "$current" == "$src" ]]; then
        ln -sfn "$src" "$dest"
        return
      fi
    fi
    if [[ "$FORCE" != "1" ]]; then
      echo "Refusing to overwrite existing $dest." >&2
      echo "Re-run with --force if you want to replace it with $src." >&2
      exit 1
    fi
    if [[ -d "$dest" && ! -L "$dest" ]]; then
      echo "Refusing to overwrite directory $dest." >&2
      exit 1
    fi
  fi
  ln -sfn "$src" "$dest"
}

link_command "$REPO_DIR/bin/peer" "$BIN_DIR/peer"
link_command "$REPO_DIR/start.sh" "$BIN_DIR/agent-duo-start"
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
echo "  1. cd <your-project> && agent-duo-start"
echo "  2. Approve the first-run prompt to inject peer instructions, or pass -y for non-interactive setup"
echo "  3. tmux -CC attach -t agents"
echo "Manual fallback: append docs/AGENT-INSTRUCTIONS.md to your project's CLAUDE.md and AGENTS.md."
