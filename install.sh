#!/usr/bin/env bash
# CVM installer - bootstraps CVM itself
# Usage: curl -fsSL https://raw.githubusercontent.com/alexandernicholson/cvm/main/install.sh | bash
set -euo pipefail

CVM_DIR="${CVM_DIR:-$HOME/.cvm}"
CVM_BIN="$CVM_DIR/bin"
CVM_SCRIPT_URL="https://raw.githubusercontent.com/alexandernicholson/cvm/main/cvm.sh"

RED='\033[0;31m' GREEN='\033[0;32m' BLUE='\033[0;34m' BOLD='\033[1m' RESET='\033[0m'

info() { echo -e "${BLUE}→${RESET} $*"; }
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
die()  { echo -e "${RED}error:${RESET} $*" >&2; exit 1; }

# Require curl
command -v curl &>/dev/null || die "curl is required to install CVM"

echo -e "${BOLD}Installing CVM - Claude (Code) Version Manager${RESET}"
echo ""

# Create directories
mkdir -p "$CVM_BIN"

# Download cvm.sh
info "Downloading cvm.sh..."
curl -fsSL --max-time 30 "$CVM_SCRIPT_URL" -o "$CVM_BIN/cvm" \
  || die "Failed to download CVM from $CVM_SCRIPT_URL"
chmod +x "$CVM_BIN/cvm"

ok "CVM installed to $CVM_BIN/cvm"
echo ""

# Detect shell and rc file
detect_rc_file() {
  local shell_name
  shell_name=$(basename "${SHELL:-bash}")
  case "$shell_name" in
    zsh)   echo "$HOME/.zshrc" ;;
    fish)  echo "$HOME/.config/fish/config.fish" ;;
    *)     echo "$HOME/.bashrc" ;;
  esac
}

RC_FILE=$(detect_rc_file)
EXPORT_LINE='export PATH="$HOME/.cvm/bin:$PATH"'

# Check if already in PATH
if echo "${PATH:-}" | tr ':' '\n' | grep -qx "$CVM_BIN"; then
  ok "~/.cvm/bin is already in your PATH"
else
  # Offer to add to rc file
  echo -e "${BOLD}Shell setup${RESET}"
  echo "Add this to your shell rc file to use cvm:"
  echo ""
  echo "  $EXPORT_LINE"
  echo ""

  if [[ -f "$RC_FILE" ]] && ! grep -qF '.cvm/bin' "$RC_FILE" 2>/dev/null; then
    printf "Auto-add to %s? [Y/n] " "$RC_FILE"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
      echo "" >> "$RC_FILE"
      echo "# CVM - Claude (Code) Version Manager" >> "$RC_FILE"
      echo "$EXPORT_LINE" >> "$RC_FILE"
      ok "Added to $RC_FILE"
      echo "  Reload with: source $RC_FILE"
    else
      echo "  Add it manually, then reload your shell."
    fi
  fi
fi

echo ""
ok "CVM is ready. Next steps:"
echo ""
echo "  1. Reload your shell (or open a new terminal)"
echo "  2. Install Claude Code:  cvm install latest"
echo "  3. Run it:               claude --version"
echo ""
echo "  cvm help   — show all commands"
