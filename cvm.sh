#!/usr/bin/env bash
# CVM - Claude (Code) Version Manager
# https://github.com/alexandernicholson/cvm
set -euo pipefail

CVM_SELF_VERSION="0.1.0"
CVM_DIR="${CVM_DIR:-$HOME/.cvm}"
CVM_BIN="$CVM_DIR/bin"
CVM_VERSIONS="$CVM_DIR/versions"
CVM_CACHE="$CVM_DIR/cache"
CVM_DEFAULT_FILE="$CVM_DIR/version"

CVM_DIST_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
CVM_NPM_REGISTRY="https://registry.npmjs.org/@anthropic-ai/claude-code"
CVM_GITHUB_RAW="https://raw.githubusercontent.com/alexandernicholson/cvm/main/cvm.sh"

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
  BLUE='\033[0;34m' BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

# ── Logging ───────────────────────────────────────────────────────────────────
err()  { echo -e "${RED}error:${RESET} $*" >&2; }
info() { echo -e "${BLUE}→${RESET} $*"; }
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
warn() { echo -e "${YELLOW}warn:${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# ── Platform Detection ────────────────────────────────────────────────────────
detect_platform() {
  local os arch

  os=$(uname -s)
  arch=$(uname -m)

  # Detect Rosetta 2: arm64 Mac running under x86_64 shell
  if [[ "$os" == "Darwin" && "$arch" == "x86_64" ]]; then
    if sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -q "Apple"; then
      arch="arm64"
    fi
  fi

  case "$os" in
    Darwin)
      case "$arch" in
        arm64|aarch64) echo "darwin-arm64" ;;
        x86_64)        echo "darwin-x64" ;;
        *) die "Unsupported macOS architecture: $arch" ;;
      esac
      ;;
    Linux)
      local musl=""
      ldd /bin/sh 2>/dev/null | grep -q musl && musl="-musl"
      case "$arch" in
        aarch64|arm64) echo "linux-arm64${musl}" ;;
        x86_64)        echo "linux-x64${musl}" ;;
        *) die "Unsupported Linux architecture: $arch" ;;
      esac
      ;;
    *)
      die "Unsupported OS: $os. CVM supports macOS and Linux."
      ;;
  esac
}

# ── JSON Helpers (no jq required) ────────────────────────────────────────────
_py() {
  if command -v python3 &>/dev/null; then python3 "$@"
  elif command -v python &>/dev/null; then python "$@"
  else return 1
  fi
}

# Extract the SHA256 checksum for $platform from manifest JSON on stdin
checksum_from_manifest() {
  local platform="$1"
  local json="$2"

  if command -v jq &>/dev/null; then
    echo "$json" | jq -r ".platforms[\"$platform\"].checksum // empty"
  elif _py -c "" 2>/dev/null; then
    _py - "$platform" <<'PYEOF'
import sys, json
platform = sys.argv[1]
data = json.load(sys.stdin)
print(data.get("platforms", {}).get(platform, {}).get("checksum", ""))
PYEOF
    echo "$json" | _py - "$platform"
  else
    echo ""  # skip verification gracefully
  fi
}

# List 2.x versions from npm JSON on stdin, sorted
versions_from_npm() {
  local json="$1"
  if command -v jq &>/dev/null; then
    echo "$json" | jq -r '.versions | keys[] | select(startswith("2."))' | sort -V
  elif _py -c "" 2>/dev/null; then
    echo "$json" | _py -c '
import sys, json
data = json.load(sys.stdin)
vs = [v for v in data.get("versions", {}) if v.startswith("2.")]
vs.sort(key=lambda v: [int(x) for x in v.split(".")])
print("\n".join(vs))
'
  else
    die "jq or python3 required for listing remote versions"
  fi
}

# ── Checksum Verification ─────────────────────────────────────────────────────
verify_checksum() {
  local file="$1" expected="$2"

  if [[ -z "$expected" ]]; then
    warn "No checksum in manifest, skipping verification"
    return 0
  fi

  local actual
  if command -v sha256sum &>/dev/null; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  elif command -v shasum &>/dev/null; then
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
  else
    warn "sha256sum/shasum not found, skipping checksum verification"
    return 0
  fi

  if [[ "$actual" != "$expected" ]]; then
    err "Checksum mismatch for $(basename "$file")"
    err "  expected: $expected"
    err "  actual:   $actual"
    return 1
  fi
}

# ── Version Channel Resolution ────────────────────────────────────────────────
# Resolves "latest" or "stable" -> actual semver. Passes through anything else.
resolve_channel() {
  local spec="$1"
  case "$spec" in
    latest|stable)
      local ver
      ver=$(curl -fsSL --max-time 10 "$CVM_DIST_BASE/$spec") \
        || die "Failed to resolve '$spec' channel"
      echo "${ver//[$'\t\r\n ']}"
      ;;
    v*)
      # strip leading v (e.g. v2.1.71 -> 2.1.71)
      echo "${spec#v}"
      ;;
    *)
      echo "$spec"
      ;;
  esac
}

# ── Active Version Resolution ─────────────────────────────────────────────────
# Resolution order:
#   1. $CVM_VERSION env var
#   2. .claude-version file (walk up from $PWD to $HOME)
#   3. ~/.cvm/version global default
#
# Returns 0 + prints version on success, returns 1 if nothing found.
cvm_resolve_version() {
  # 1. Environment variable
  if [[ -n "${CVM_VERSION:-}" ]]; then
    echo "${CVM_VERSION//[$'\t\r\n ']}"
    return 0
  fi

  # 2. Walk up directory tree
  local dir="$PWD"
  while true; do
    if [[ -f "$dir/.claude-version" ]]; then
      local v
      v=$(tr -d '[:space:]' < "$dir/.claude-version")
      [[ -n "$v" ]] && { echo "$v"; return 0; }
    fi
    [[ "$dir" == "/" ]] && break
    dir=$(dirname "$dir")
  done

  # 3. Global default
  if [[ -f "$CVM_DEFAULT_FILE" ]]; then
    local v
    v=$(tr -d '[:space:]' < "$CVM_DEFAULT_FILE")
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  fi

  return 1
}

# ── Symlink Management ────────────────────────────────────────────────────────
update_symlink() {
  local version="$1"
  local target="$CVM_VERSIONS/$version/claude"
  local link="$CVM_BIN/claude"

  [[ -f "$target" ]] || die "Version $version not installed at $target"
  ln -sf "$target" "$link"
}

# ── Directory Setup ───────────────────────────────────────────────────────────
setup_dirs() {
  mkdir -p "$CVM_BIN" "$CVM_VERSIONS" "$CVM_CACHE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Commands
# ═══════════════════════════════════════════════════════════════════════════════

cmd_install() {
  local spec="${1:-latest}"
  setup_dirs

  info "Resolving version: $spec"
  local version
  version=$(resolve_channel "$spec")
  [[ -n "$version" ]] || die "Could not resolve version from spec: $spec"

  local platform
  platform=$(detect_platform)

  local version_dir="$CVM_VERSIONS/$version"
  local binary_path="$version_dir/claude"

  if [[ -f "$binary_path" ]]; then
    ok "Claude Code $version already installed"
    # Still set as default if none set
    if [[ ! -f "$CVM_DEFAULT_FILE" ]]; then
      echo "$version" > "$CVM_DEFAULT_FILE"
      update_symlink "$version"
      ok "Set $version as default"
    fi
    return 0
  fi

  info "Installing Claude Code $version for platform $platform"

  # Fetch manifest for checksum
  local manifest_url="$CVM_DIST_BASE/$version/manifest.json"
  info "Fetching manifest..."
  local manifest
  manifest=$(curl -fsSL --max-time 15 "$manifest_url") \
    || die "Failed to fetch manifest for $version. Version may not exist."

  local checksum
  checksum=$(checksum_from_manifest "$platform" "$manifest")

  # Download binary to cache (atomic: download then move)
  local binary_url="$CVM_DIST_BASE/$version/$platform/claude"
  local tmp_file
  tmp_file=$(mktemp "$CVM_CACHE/claude-${version}-XXXXXX")

  info "Downloading claude $version..."
  if ! curl -fL --max-time 300 --progress-bar "$binary_url" -o "$tmp_file"; then
    rm -f "$tmp_file"
    die "Download failed: $binary_url"
  fi

  # Verify
  info "Verifying checksum..."
  if ! verify_checksum "$tmp_file" "$checksum"; then
    rm -f "$tmp_file"
    die "Checksum verification failed. Aborting install."
  fi

  # Install
  mkdir -p "$version_dir"
  mv "$tmp_file" "$binary_path"
  chmod +x "$binary_path"

  ok "Installed Claude Code $version"

  # Set as default if no default exists
  if [[ ! -f "$CVM_DEFAULT_FILE" ]]; then
    echo "$version" > "$CVM_DEFAULT_FILE"
    update_symlink "$version"
    ok "Set $version as default"
  fi
}

cmd_use() {
  local spec="${1:-}"
  [[ -n "$spec" ]] || die "Usage: cvm use <version|latest|stable>"

  local version
  version=$(resolve_channel "$spec")

  [[ -d "$CVM_VERSIONS/$version" ]] \
    || die "Version $version is not installed. Run: cvm install $version"

  update_symlink "$version"
  echo "$version" > "$CVM_DEFAULT_FILE"
  ok "Now using Claude Code $version (global)"
}

cmd_local() {
  local spec="${1:-}"
  [[ -n "$spec" ]] || die "Usage: cvm local <version|latest|stable>"

  local version
  version=$(resolve_channel "$spec")

  if [[ ! -d "$CVM_VERSIONS/$version" ]]; then
    warn "Version $version is not installed. Install it with: cvm install $version"
  fi

  echo "$version" > ".claude-version"
  ok "Wrote .claude-version: $version"
}

cmd_current() {
  local version
  if version=$(cvm_resolve_version 2>/dev/null); then
    echo "$version"
  else
    echo "none"
    return 1
  fi
}

cmd_which() {
  local version
  version=$(cvm_resolve_version) \
    || die "No version active. Run: cvm use <version>"

  local binary="$CVM_VERSIONS/$version/claude"
  [[ -f "$binary" ]] \
    || die "Version $version is not installed. Run: cvm install $version"

  echo "$binary"
}

cmd_list() {
  local current
  current=$(cvm_resolve_version 2>/dev/null || echo "")

  if [[ ! -d "$CVM_VERSIONS" ]] || [[ -z "$(ls -A "$CVM_VERSIONS" 2>/dev/null)" ]]; then
    echo "No versions installed."
    echo "Run: cvm install latest"
    return 0
  fi

  echo "Installed versions:"
  local found=0
  for ver_dir in "$CVM_VERSIONS"/*/; do
    [[ -d "$ver_dir" ]] || continue
    local ver
    ver=$(basename "$ver_dir")
    found=1
    if [[ "$ver" == "$current" ]]; then
      echo -e "  ${GREEN}→ $ver${RESET}  ${DIM}(active)${RESET}"
    else
      echo "    $ver"
    fi
  done
  [[ $found -eq 1 ]] || echo "  (none)"
}

cmd_list_remote() {
  local show_all="${1:-}"

  info "Fetching available versions from npm registry..."
  local npm_data
  npm_data=$(curl -fsSL --max-time 20 "$CVM_NPM_REGISTRY") \
    || die "Failed to fetch npm registry data"

  local all_versions
  all_versions=$(versions_from_npm "$npm_data")

  local latest stable
  latest=$(curl -fsSL --max-time 10 "$CVM_DIST_BASE/latest" | tr -d '[:space:]')
  stable=$(curl -fsSL --max-time 10 "$CVM_DIST_BASE/stable" | tr -d '[:space:]')

  local versions="$all_versions"
  if [[ -z "$show_all" ]]; then
    versions=$(echo "$all_versions" | tail -20)
    local total
    total=$(echo "$all_versions" | wc -l | tr -d ' ')
    echo "Available versions (last 20 of $total, use --all to see all):"
  else
    echo "Available versions:"
  fi

  while IFS= read -r ver; do
    local label=""
    [[ "$ver" == "$latest" ]] && label="${label}${GREEN} ← latest${RESET}"
    [[ "$ver" == "$stable" && "$stable" != "$latest" ]] && \
      label="${label}${BLUE} ← stable${RESET}"
    echo -e "  $ver$label"
  done <<< "$versions"
}

cmd_uninstall() {
  local version="${1:-}"
  [[ -n "$version" ]] || die "Usage: cvm uninstall <version>"

  # Don't try to resolve channels for uninstall — must be exact version
  version="${version#v}"

  local version_dir="$CVM_VERSIONS/$version"
  [[ -d "$version_dir" ]] || die "Version $version is not installed"

  local current
  current=$(cvm_resolve_version 2>/dev/null || echo "")
  if [[ "$current" == "$version" ]]; then
    warn "Version $version is currently active"
    rm -f "$CVM_BIN/claude" "$CVM_DEFAULT_FILE"
    warn "Active version cleared. Run 'cvm use <version>' to set another."
  fi

  rm -rf "$version_dir"
  ok "Uninstalled Claude Code $version"
}

cmd_self_update() {
  local script_path
  # Resolve the real path of this script (follow symlinks)
  if command -v realpath &>/dev/null; then
    script_path=$(realpath "${BASH_SOURCE[0]}")
  elif command -v readlink &>/dev/null; then
    script_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null \
      || readlink "${BASH_SOURCE[0]}")
  else
    script_path="${BASH_SOURCE[0]}"
  fi

  info "Updating CVM from $CVM_GITHUB_RAW"
  local tmp
  tmp=$(mktemp)
  if ! curl -fsSL --max-time 30 "$CVM_GITHUB_RAW" -o "$tmp"; then
    rm -f "$tmp"
    die "Failed to download CVM update"
  fi

  # Sanity check: must look like a shell script
  head -1 "$tmp" | grep -q "bash" || { rm -f "$tmp"; die "Downloaded file doesn't look like a shell script"; }

  chmod +x "$tmp"
  mv "$tmp" "$script_path"
  ok "CVM updated to latest version"
  "$script_path" --version
}

cmd_self_uninstall() {
  echo -e "${YELLOW}This will remove CVM and all installed Claude Code versions.${RESET}"
  echo -e "  Removing: ${BOLD}$CVM_DIR${RESET}"
  printf "Are you sure? [y/N] "
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }

  rm -rf "$CVM_DIR"
  ok "CVM removed."
  echo ""
  echo "Remove the following line from your shell rc file (~/.bashrc, ~/.zshrc):"
  echo -e "  ${DIM}export PATH=\"\$HOME/.cvm/bin:\$PATH\"${RESET}"
}

cmd_env() {
  # Print shell setup snippet (for eval or manual copy)
  cat <<'EOF'
export PATH="$HOME/.cvm/bin:$PATH"
EOF
}

cmd_help() {
  cat <<EOF
${BOLD}cvm${RESET} ${DIM}v${CVM_SELF_VERSION}${RESET} — Claude (Code) Version Manager

${BOLD}USAGE${RESET}
  cvm <command> [args]

${BOLD}COMMANDS${RESET}
  ${BOLD}install${RESET} <version>      Install a Claude Code version
                         (version: semver, ${GREEN}latest${RESET}, ${BLUE}stable${RESET})
  ${BOLD}use${RESET} <version>          Set the global (system-wide) active version
  ${BOLD}local${RESET} <version>        Set per-directory version (writes .claude-version)
  ${BOLD}current${RESET}               Show the currently resolved version
  ${BOLD}which${RESET}                 Print path to the active claude binary
  ${BOLD}ls${RESET}, ${BOLD}list${RESET}             List installed versions
  ${BOLD}ls-remote${RESET} [--all]     List versions available for download
  ${BOLD}uninstall${RESET} <version>   Remove an installed version
  ${BOLD}self-update${RESET}           Update CVM itself
  ${BOLD}self-uninstall${RESET}        Remove CVM and all installed versions
  ${BOLD}env${RESET}                   Print the PATH export line for shell setup
  ${BOLD}version${RESET}              Show CVM version

${BOLD}VERSION RESOLUTION ORDER${RESET}
  1. \$CVM_VERSION environment variable
  2. .claude-version file (walks up directory tree to \$HOME)
  3. ~/.cvm/version (global default, set by ${BOLD}cvm use${RESET})

${BOLD}SHELL SETUP${RESET}
  Add this to ~/.bashrc or ~/.zshrc:
    ${DIM}export PATH="\$HOME/.cvm/bin:\$PATH"${RESET}

${BOLD}EXAMPLES${RESET}
  cvm install latest          Install latest available version
  cvm install stable          Install stable channel version
  cvm install 2.1.58          Install a specific version
  cvm use 2.1.71              Switch global version
  cvm local 2.1.58            Pin this directory to 2.1.58
  cvm ls-remote --all         Show all available versions
  cvm uninstall 2.1.50        Remove an old version

${BOLD}DIRECTORIES${RESET}
  Versions:  ${DIM}~/.cvm/versions/<version>/claude${RESET}
  Active:    ${DIM}~/.cvm/bin/claude -> ~/.cvm/versions/<version>/claude${RESET}
  Default:   ${DIM}~/.cvm/version${RESET}
EOF
}

# ── Main Dispatch ─────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    install)                cmd_install "$@" ;;
    use|default)            cmd_use "$@" ;;
    local)                  cmd_local "$@" ;;
    current)                cmd_current ;;
    which)                  cmd_which ;;
    ls|list)                cmd_list ;;
    ls-remote|list-remote)
      local all=""
      [[ "${1:-}" == "--all" ]] && all="yes"
      cmd_list_remote "$all"
      ;;
    uninstall|remove)       cmd_uninstall "$@" ;;
    self-update)            cmd_self_update ;;
    self-uninstall)         cmd_self_uninstall ;;
    env)                    cmd_env ;;
    version|--version|-v)  echo "cvm $CVM_SELF_VERSION" ;;
    help|--help|-h)         cmd_help ;;
    *)
      err "Unknown command: $cmd"
      echo ""
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
