#!/usr/bin/env bash
# CVM - Claude (Code) Version Manager
# https://github.com/alexandernicholson/cvm
set -euo pipefail

CVM_SELF_VERSION="0.2.1"
CVM_DIR="${CVM_DIR:-$HOME/.cvm}"
CVM_BIN="$CVM_DIR/bin"
CVM_VERSIONS="$CVM_DIR/versions"
CVM_CACHE="$CVM_DIR/cache"
CVM_DEFAULT_FILE="$CVM_DIR/version"
CVM_PLUGINS="$CVM_DIR/plugins"
CVM_ENV_D="$CVM_DIR/env.d"

CVM_DIST_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
CVM_NPM_REGISTRY="https://registry.npmjs.org/@anthropic-ai/claude-code"
CVM_GITHUB_TAGS="https://api.github.com/repos/anthropics/claude-code/tags"
CVM_GITHUB_RAW="https://raw.githubusercontent.com/alexandernicholson/cvm/main/cvm.sh"

# ── Colors ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m' BOLD=$'\033[1m'      DIM=$'\033[2m'    RESET=$'\033[0m'
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
    MINGW*|MSYS*)
      case "$arch" in
        x86_64)        echo "win32-x64" ;;
        aarch64|arm64) echo "win32-arm64" ;;
        *) die "Unsupported Windows architecture: $arch" ;;
      esac
      ;;
    CYGWIN*)
      echo "win32-x64"
      ;;
    *)
      die "Unsupported OS: $os. CVM supports macOS, Linux, and Windows (Git Bash/MSYS2/Cygwin)."
      ;;
  esac
}

# Returns the binary filename for a given platform (claude or claude.exe)
binary_name_for_platform() {
  case "${1:-}" in
    win32-*) echo "claude.exe" ;;
    *)       echo "claude" ;;
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

# Extract 2.x versions from npm registry JSON (unsorted, one per line)
versions_from_npm() {
  local json="$1"
  if command -v jq &>/dev/null; then
    echo "$json" | jq -r '.versions | keys[] | select(startswith("2."))'
  elif _py -c "" 2>/dev/null; then
    echo "$json" | _py -c '
import sys, json
data = json.load(sys.stdin)
for v in data.get("versions", {}):
    if v.startswith("2."):
        print(v)
'
  else
    echo ""
  fi
}

# Extract 2.x versions from GitHub tags JSON (unsorted, one per line)
versions_from_github() {
  local json="$1"
  if command -v jq &>/dev/null; then
    echo "$json" | jq -r '.[].name | ltrimstr("v") | select(startswith("2."))'
  elif _py -c "" 2>/dev/null; then
    echo "$json" | _py -c '
import sys, json
for t in json.load(sys.stdin):
    v = t.get("name", "").lstrip("v")
    if v.startswith("2."):
        print(v)
'
  else
    echo ""
  fi
}

# Sort and deduplicate a newline-separated list of semver strings
sort_versions() {
  local input="$1"
  if _py -c "" 2>/dev/null; then
    echo "$input" | _py -c '
import sys
vs = list({v.strip() for v in sys.stdin if v.strip()})
try:
    vs.sort(key=lambda v: [int(x) for x in v.split(".")])
except Exception:
    vs.sort()
print("\n".join(vs))
'
  elif command -v sort &>/dev/null; then
    echo "$input" | grep -v "^$" | sort -u
  else
    echo "$input" | grep -v "^$"
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

# ── Shim Management ───────────────────────────────────────────────────────────
# The active `claude` on $PATH is a bash wrapper (on unix) that:
#   1. resolves the active version (same order as cvm_resolve_version),
#   2. sources ~/.cvm/env.d/*.sh env hooks (used by plugins, e.g. the cvp
#      profile plugin, to inject ANTHROPIC_BASE_URL / tokens / flags), and
#   3. execs the real versioned binary.
# On win32 we keep the legacy symlink/copy: the env-hook wrapper is bash/Git-Bash
# only; native PowerShell users go through cvm.ps1.

# Write the bash wrapper at $CVM_BIN/claude. On unix the binary is always named
# "claude", so the name is baked in literally; win32 never reaches this path.
_write_claude_wrapper() {
  local shim="$CVM_BIN/claude"
  # Remove any existing entry first: if it's a symlink, `cat >` would follow it
  # and clobber the versioned binary it points to instead of replacing it.
  rm -f "$shim"
  cat > "$shim" <<'SHIM'
#!/usr/bin/env bash
# Auto-generated by cvm — do not edit.
# Resolves the active Claude Code version, sources ~/.cvm/env.d/*.sh env hooks
# (so plugins can inject environment), then execs the real versioned binary.
_CVM_DIR="${CVM_DIR:-$HOME/.cvm}"
if [[ -d "$_CVM_DIR/env.d" ]]; then
  for _f in "$_CVM_DIR"/env.d/*.sh; do
    [[ -f "$_f" ]] && . "$_f"
  done
fi
_cvm_resolve() {
  if [[ -n "${CVM_VERSION:-}" ]]; then printf '%s' "$CVM_VERSION"; return 0; fi
  local dir="$PWD"
  while true; do
    if [[ -f "$dir/.claude-version" ]]; then
      local v; v=$(tr -d '[:space:]' < "$dir/.claude-version")
      [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
    fi
    [[ "$dir" == "/" ]] && break
    dir=$(dirname "$dir")
  done
  if [[ -f "$_CVM_DIR/version" ]]; then
    tr -d '[:space:]' < "$_CVM_DIR/version"; return 0
  fi
  return 1
}
_ver=$(_cvm_resolve) || { echo "cvm: no version active. Run: cvm use <version>" >&2; exit 1; }
_bin="$_CVM_DIR/versions/$_ver/claude"
[[ -f "$_bin" ]] || { echo "cvm: version $_ver not installed. Run: cvm install $_ver" >&2; exit 1; }
exec "$_bin" "$@"
SHIM
  chmod +x "$shim"
}

# Install the active-version shim for $1 (a version that is already installed).
install_claude_shim() {
  local version="$1"
  local platform
  platform=$(detect_platform)
  local bin_name
  bin_name=$(binary_name_for_platform "$platform")
  local target="$CVM_VERSIONS/$version/$bin_name"

  [[ -f "$target" ]] || die "Version $version not installed at $target"
  mkdir -p "$CVM_BIN"

  case "$platform" in
    win32-*)
      # Windows native: keep direct symlink/copy (env-hook wrapper is bash-only).
      ln -sf "$target" "$CVM_BIN/$bin_name" 2>/dev/null || cp -f "$target" "$CVM_BIN/$bin_name"
      ;;
    *)
      _write_claude_wrapper
      ;;
  esac
}

# ── Directory Setup ───────────────────────────────────────────────────────────
setup_dirs() {
  mkdir -p "$CVM_BIN" "$CVM_VERSIONS" "$CVM_CACHE" "$CVM_PLUGINS" "$CVM_ENV_D"
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
  local bin_name
  bin_name=$(binary_name_for_platform "$platform")

  local version_dir="$CVM_VERSIONS/$version"
  local binary_path="$version_dir/$bin_name"

  if [[ -f "$binary_path" ]]; then
    ok "Claude Code $version already installed"
    # Still set as default if none set
    if [[ ! -f "$CVM_DEFAULT_FILE" ]]; then
      echo "$version" > "$CVM_DEFAULT_FILE"
      install_claude_shim "$version"
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
  local binary_url="$CVM_DIST_BASE/$version/$platform/$bin_name"
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
    install_claude_shim "$version"
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

  install_claude_shim "$version"
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

  local platform
  platform=$(detect_platform)
  local bin_name
  bin_name=$(binary_name_for_platform "$platform")
  local binary="$CVM_VERSIONS/$version/$bin_name"
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

  info "Fetching available versions..."

  # Query both sources independently; each is optional so a single outage
  # doesn't break the command. Results are merged and deduplicated.
  local gh_versions="" npm_versions=""

  local gh_data
  if gh_data=$(curl -fsSL --max-time 10 "${CVM_GITHUB_TAGS}?per_page=100" 2>/dev/null); then
    gh_versions=$(versions_from_github "$gh_data" 2>/dev/null) || gh_versions=""
  fi

  local npm_data
  if npm_data=$(curl -fsSL --max-time 20 "$CVM_NPM_REGISTRY" 2>/dev/null); then
    npm_versions=$(versions_from_npm "$npm_data" 2>/dev/null) || npm_versions=""
  fi

  [[ -n "$gh_versions" || -n "$npm_versions" ]] \
    || die "Failed to fetch available versions (GitHub and npm registry both unavailable)"

  local all_versions
  all_versions=$(sort_versions "$(printf '%s\n%s\n' "$gh_versions" "$npm_versions")")

  local latest stable
  latest=$(curl -fsSL --max-time 10 "$CVM_DIST_BASE/latest" 2>/dev/null | tr -d '[:space:]') || latest=""
  stable=$(curl -fsSL --max-time 10 "$CVM_DIST_BASE/stable" 2>/dev/null | tr -d '[:space:]') || stable=""

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
    rm -f "$CVM_BIN/claude" "$CVM_BIN/claude.exe" "$CVM_DEFAULT_FILE"
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
  # Regenerate the `claude` shim so new wrapper logic (e.g. env.d sourcing) takes
  # effect immediately. Invoked through the freshly-written script so the NEW
  # code runs (the in-memory process is still the old version).
  "$script_path" _refresh-shim 2>/dev/null || true
}

# Hidden command: regenerate the active `claude` shim for the currently
# resolved version. Used by self-update so a script update lands the new wrapper
# without requiring the user to re-run `cvm use`.
_refresh_shim() {
  local version
  if version=$(cvm_resolve_version 2>/dev/null); then
    if [[ -d "$CVM_VERSIONS/$version" ]]; then
      install_claude_shim "$version"
      info "Refreshed claude shim for $version"
    fi
  fi
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
  echo "Remove the CVM PATH line from your shell config:"
  echo -e "  bash/zsh  ${DIM}~/.bashrc or ~/.zshrc${RESET}"
  echo -e "  fish      ${DIM}~/.config/fish/config.fish${RESET}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Plugin Manager
# ═══════════════════════════════════════════════════════════════════════════════
# Plugins live in $CVM_PLUGINS/<name>/ and register a subcommand via plugin.sh:
#   CVM_PLUGIN_NAME, CVM_PLUGIN_COMMAND, CVM_PLUGIN_VERSION, CVM_PLUGIN_DESCRIPION
#   function cvm_plugin_main() { ...; }   # invoked with args after the subcommand
# cvm sources ~/.cvm/env.d/*.sh before exec'ing the real claude binary, so plugins
# can inject environment variables (see the cvp profile plugin).

# Source $1 (a plugin.sh) in a throwaway subshell and print $2 (a var name).
_plugin_read_var() {
  local file="$1" var="$2" default="$3"
  {
    # shellcheck disable=SC1090
    source "$file" 2>/dev/null || true
    printf '%s' "${!var:-$default}"
  }
}

# Normalize a plugin source spec to a cloneable URL and echo "url<TAB>name".
_plugin_normalize_source() {
  local src="$1" url name
  case "$src" in
    http://*|https://*|git@*|file://*|ssh://*|/*)
      url="$src"
      ;;
    */*)
      url="https://github.com/$src.git"
      ;;
    *)
      return 1
      ;;
  esac
  name="$(basename "$url")"
  name="${name%.git}"
  [[ -n "$name" ]] || return 1
  printf '%s\t%s' "$url" "$name"
}

_plugin_install() {
  local src="${1:-}"
  [[ -n "$src" ]] || die "Usage: cvm plugin install <owner/repo|url>"
  setup_dirs

  local norm url name
  norm=$(_plugin_normalize_source "$src") || die "Invalid plugin source: $src (use 'owner/repo' or a git URL)"
  url="${norm%%$'\t'*}"
  name="${norm#*$'\t'}"

  local dest="$CVM_PLUGINS/$name"
  if [[ -d "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    warn "Plugin '$name' already installed at $dest"
    echo "  Use ${BOLD}cvm plugin update $name${RESET} to update, or ${BOLD}cvm plugin uninstall $name${RESET} first."
    return 0
  fi

  command -v git &>/dev/null || die "git is required to install plugins"

  info "Installing plugin '$name' from $url"
  if ! git clone --depth 1 "$url" "$dest" 2>/tmp/cvm-plugin-clone.err; then
    rm -rf "$dest"
    err "Failed to clone $url"
    [[ -s /tmp/cvm-plugin-clone.err ]] && cat /tmp/cvm-plugin-clone.err >&2
    return 1
  fi

  [[ -f "$dest/plugin.sh" ]] || { rm -rf "$dest"; die "Plugin '$name' has no plugin.sh — not a valid cvm plugin."; }

  local pcmd pver
  pcmd=$(_plugin_read_var "$dest/plugin.sh" CVM_PLUGIN_COMMAND "$name")
  pver=$(_plugin_read_var "$dest/plugin.sh" CVM_PLUGIN_VERSION "")

  ok "Installed plugin '$name'"
  echo -e "  ${DIM}command:${RESET} cvm $pcmd   ${DIM}version:${RESET} ${pver:-unknown}"
  echo -e "  ${DIM}get started:${RESET} cvm $pcmd help"

  # Run the plugin's post-install hook (cvm_plugin_init) if it defines one —
  # e.g. cvp seeds a `default` profile and installs its env.d resolver here.
  _plugin_run_init "$dest" "$name"
}

# Source a plugin's plugin.sh in an isolated subshell and, if it defines
# cvm_plugin_init(), run it. Used on install and update. Failures are warned,
# not fatal (the plugin still installed; its setup can be run manually).
_plugin_run_init() {
  local dest="$1" name="$2"
  local init_rc=0
  (
    # shellcheck disable=SC1090
    source "$dest/plugin.sh" 2>/dev/null || exit 0
    if declare -F cvm_plugin_init >/dev/null 2>&1; then
      cvm_plugin_init
    fi
  ) || init_rc=$?
  if [[ $init_rc -ne 0 ]]; then
    warn "Plugin '$name' init hook exited $init_rc — you may need to run its setup manually"
  fi
}

_plugin_list() {
  setup_dirs
  if [[ ! -d "$CVM_PLUGINS" ]] || [[ -z "$(ls -A "$CVM_PLUGINS" 2>/dev/null)" ]]; then
    echo "No plugins installed."
    echo "Install with: cvm plugin install <owner/repo>"
    return 0
  fi

  echo "Installed plugins:"
  local found=0 pdir pfile pname pcmd pver pdesc
  for pdir in "$CVM_PLUGINS"/*/; do
    [[ -d "$pdir" ]] || continue
    pfile="${pdir}plugin.sh"
    pname="$(basename "$pdir")"
    [[ -f "$pfile" ]] || { echo -e "  ${YELLOW}$pname${RESET}  ${DIM}(no plugin.sh — broken)${RESET}"; found=1; continue; }
    pcmd=$(_plugin_read_var "$pfile" CVM_PLUGIN_COMMAND "$pname")
    pver=$(_plugin_read_var "$pfile" CVM_PLUGIN_VERSION "")
    pdesc=$(_plugin_read_var "$pfile" CVM_PLUGIN_DESCRIPION "")
    found=1
    printf "  %s%s%s  ->  cvm %s" "$GREEN" "$pname" "$RESET" "$pcmd"
    [[ -n "$pver" ]]  && printf "  %sv%s%s" "$DIM" "$pver" "$RESET"
    printf "\n"
    [[ -n "$pdesc" ]] && printf "      %s%s%s\n" "$DIM" "$pdesc" "$RESET"
  done
  [[ $found -eq 1 ]] || echo "  (none)"
}

_plugin_uninstall() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: cvm plugin uninstall <name>"
  local dest="$CVM_PLUGINS/$name"
  [[ -d "$dest" ]] || die "Plugin '$name' is not installed"
  rm -rf "$dest"
  ok "Uninstalled plugin '$name'"
}

_plugin_update() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "Usage: cvm plugin update <name>"
  local dest="$CVM_PLUGINS/$name"
  [[ -d "$dest" ]] || die "Plugin '$name' is not installed"
  command -v git &>/dev/null || die "git is required to update plugins"
  info "Updating plugin '$name'"
  if ! git -C "$dest" pull --ff-only 2>/dev/null; then
    die "Failed to update '$name' (local changes or upstream moved). Reinstall with: cvm plugin uninstall $name && cvm plugin install <src>"
  fi
  # Re-run the plugin's init hook so post-install setup (seeding, resolver
  # refresh) reflects the newly-pulled code.
  _plugin_run_init "$dest" "$name"
  ok "Updated plugin '$name"
}

_plugin_help() {
  cat <<EOF
${BOLD}cvm plugin${RESET} ${DIM}— manage cvm plugins${RESET}

${BOLD}USAGE${RESET}
  cvm plugin <command> [args]

${BOLD}COMMANDS${RESET}
  ${BOLD}install${RESET} <owner/repo|url>   Install a plugin from GitHub (owner/repo) or any git URL
  ${BOLD}list${RESET}, ${BOLD}ls${RESET}                  List installed plugins
  ${BOLD}update${RESET} <name>            Update a plugin (git pull --ff-only)
  ${BOLD}uninstall${RESET} <name>         Remove a plugin

${BOLD}PLUGIN CONTRACT${RESET}
  A plugin is a git repo with a ${BOLD}plugin.sh${RESET} at its root that sets:
    CVM_PLUGIN_NAME, CVM_PLUGIN_COMMAND, CVM_PLUGIN_VERSION, CVM_PLUGIN_DESCRIPION
  and defines a function ${BOLD}cvm_plugin_main()${RESET}, invoked with the args
  after the subcommand. cvm also sources ${BOLD}~/.cvm/env.d/*.sh${RESET} before
  exec'ing the real claude binary, so plugins can inject environment variables
  (see the cvp profile plugin). An optional ${BOLD}cvm_plugin_init()${RESET} hook
  runs on install/update for one-shot setup (seeding, resolver install).

${BOLD}EXAMPLES${RESET}
  cvm plugin install alexandernicholson/cvp
  cvm plugin list
  cvm profile use work      ${DIM}# subcommand registered by cvp${RESET}
EOF
}

cmd_plugin() {
  local sub="${1:-help}"
  shift || true
  case "$sub" in
    install|i)    _plugin_install "$@" ;;
    list|ls)      _plugin_list ;;
    uninstall|rm) _plugin_uninstall "$@" ;;
    update|up)    _plugin_update "$@" ;;
    help|--help|-h) _plugin_help ;;
    *) err "Unknown plugin command: $sub"; echo ""; _plugin_help; return 1 ;;
  esac
}

# Dispatch an unknown top-level command to a plugin that registers it.
# Returns 0 if a plugin handled it (the plugin's own exit code is stashed in the
# global _CVM_PLUGIN_RC for main() to propagate), or 1 if no plugin matched.
_plugin_dispatch() {
  local cmd="$1"; shift || true
  [[ -d "$CVM_PLUGINS" ]] || return 1

  local pdir pfile pname pcmd
  for pdir in "$CVM_PLUGINS"/*/; do
    [[ -d "$pdir" ]] || continue
    pfile="${pdir}plugin.sh"
    [[ -f "$pfile" ]] || continue
    pname="$(basename "$pdir")"
    pcmd=$(_plugin_read_var "$pfile" CVM_PLUGIN_COMMAND "$pname")
    [[ "$pcmd" == "$cmd" ]] || continue

    # Matched. Run the plugin's main in a subshell that inherits cvm's helper
    # functions (err/ok/info/warn/die) but isolates the plugin from cvm's state.
    # `|| rc=$?` neutralises errexit so we can capture a non-zero plugin exit.
    local rc=0
    (
      # shellcheck disable=SC1090
      source "$pfile" 2>/dev/null || { echo "cvm: failed to load plugin '$pname'" >&2; exit 1; }
      if ! declare -F cvm_plugin_main >/dev/null 2>&1; then
        echo "cvm: plugin '$pname' did not define cvm_plugin_main()" >&2
        exit 1
      fi
      cvm_plugin_main "$@"
    ) || rc=$?
    _CVM_PLUGIN_RC=$rc
    return 0
  done
  return 1
}

# ── Shell Helpers ─────────────────────────────────────────────────────────────

# Normalise a shell path or name to a short name: bash, zsh, fish, sh, …
_shell_name() {
  basename "${1:-${SHELL:-bash}}"
}

# Emit the correct PATH setup line for the given shell name.
_path_setup_line() {
  local shell_name="$1"
  case "$shell_name" in
    fish)             printf 'fish_add_path %s/bin\n' "$CVM_DIR" ;;
    pwsh|powershell)  printf '$env:PATH = "%s\\bin;$env:PATH"\n' "$CVM_DIR" ;;
    *)                printf 'export PATH="%s/bin:$PATH"\n' "$CVM_DIR" ;;
  esac
}

# Return the conventional rc file path for a shell name.
_rc_file_for_shell() {
  local shell_name="$1"
  case "$shell_name" in
    zsh)              echo "$HOME/.zshrc" ;;
    fish)             echo "$HOME/.config/fish/config.fish" ;;
    pwsh|powershell)  echo "$HOME/Documents/PowerShell/profile.ps1" ;;
    *)                echo "$HOME/.bashrc" ;;
  esac
}

cmd_env() {
  local shell_name
  case "${1:-}" in
    --fish|fish)                         shell_name="fish" ;;
    --zsh|zsh)                           shell_name="zsh" ;;
    --bash|bash)                         shell_name="bash" ;;
    --sh|sh)                             shell_name="sh" ;;
    --pwsh|--powershell|pwsh|powershell) shell_name="pwsh" ;;
    "")                                  shell_name=$(_shell_name) ;;
    *)  die "Unknown shell: ${1}. Supported: bash, zsh, fish, sh, pwsh" ;;
  esac
  _path_setup_line "$shell_name"
}

cmd_help() {
  cat <<EOF
${BOLD}cvm${RESET} ${DIM}v${CVM_SELF_VERSION}${RESET} — Claude (Code) Version Manager

${BOLD}USAGE${RESET}
  cvm <command> [args]

${BOLD}COMMANDS${RESET}
  ${BOLD}install${RESET} <version>     Install a Claude Code version
                        (version: semver, ${GREEN}latest${RESET}, ${BLUE}stable${RESET})
  ${BOLD}use${RESET} <version>         Set the global (system-wide) active version
  ${BOLD}local${RESET} <version>       Set per-directory version (writes .claude-version)
  ${BOLD}current${RESET}               Show the currently resolved version
  ${BOLD}which${RESET}                 Print path to the active claude binary
  ${BOLD}ls${RESET}, ${BOLD}list${RESET}              List installed versions
  ${BOLD}ls-remote${RESET} [--all]     List versions available for download
  ${BOLD}uninstall${RESET} <version>   Remove an installed version
  ${BOLD}self-update${RESET}           Update CVM itself
  ${BOLD}self-uninstall${RESET}        Remove CVM and all installed versions
  ${BOLD}plugin${RESET} <install|list|update|uninstall>
                        Manage cvm plugins (e.g. the cvp profile manager)
  ${BOLD}env${RESET}                   Print the PATH export line for shell setup
  ${BOLD}version${RESET}               Show CVM version
  ${DIM}<plugin-command> ...${RESET}  Subcommands registered by installed plugins
                        (e.g. ${BOLD}cvm profile use work${RESET} once cvp is installed)

${BOLD}VERSION RESOLUTION ORDER${RESET}
  1. \$CVM_VERSION environment variable
  2. .claude-version file (walks up directory tree to \$HOME)
  3. ~/.cvm/version (global default, set by ${BOLD}cvm use${RESET})

${BOLD}ENV HOOKS${RESET}
  The active ${BOLD}claude${RESET} shim sources every ${BOLD}~/.cvm/env.d/*.sh${RESET}
  before exec'ing the real binary, so plugins can inject environment variables
  (ANTHROPIC_BASE_URL, tokens, feature flags, ...). See ${BOLD}cvm plugin${RESET}.

${BOLD}SHELL SETUP${RESET}
  Run ${BOLD}cvm env${RESET} to print the right line for your current shell, or:

  bash / zsh — add to ~/.bashrc or ~/.zshrc:
    ${DIM}export PATH="\$HOME/.cvm/bin:\$PATH"${RESET}

  fish — add to ~/.config/fish/config.fish:
    ${DIM}fish_add_path \$HOME/.cvm/bin${RESET}

  PowerShell — add to \$PROFILE:
    ${DIM}\$env:PATH = "\$env:USERPROFILE\.cvm\bin;\$env:PATH"${RESET}

  Flags: ${DIM}cvm env --bash${RESET}  ${DIM}cvm env --zsh${RESET}  ${DIM}cvm env --fish${RESET}  ${DIM}cvm env --pwsh${RESET}

${BOLD}EXAMPLES${RESET}
  cvm install latest          Install latest available version
  cvm install stable          Install stable channel version
  cvm install 2.1.58          Install a specific version
  cvm use 2.1.71              Switch global version
  cvm local 2.1.58            Pin this directory to 2.1.58
  cvm ls-remote --all         Show all available versions
  cvm uninstall 2.1.50        Remove an old version
  cvm plugin install alexandernicholson/cvp   Install the profile manager
  cvm profile use work        Switch profile (subcommand from cvp)

${BOLD}DIRECTORIES${RESET}
  Versions:  ${DIM}~/.cvm/versions/<version>/claude${RESET}
  Active:    ${DIM}~/.cvm/bin/claude  (wrapper; sources ~/.cvm/env.d/*.sh)${RESET}
  Default:   ${DIM}~/.cvm/version${RESET}
  Plugins:   ${DIM}~/.cvm/plugins/<name>/plugin.sh${RESET}
  Env hooks: ${DIM}~/.cvm/env.d/*.sh${RESET}
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
    plugin)                 cmd_plugin "$@" ;;
    env)                    cmd_env "$@" ;;
    version|--version|-v)  echo "cvm $CVM_SELF_VERSION" ;;
    help|--help|-h)         cmd_help ;;
    _refresh-shim)         _refresh_shim ;;
    *)
      # Fall through to a plugin that registers this subcommand.
      if _plugin_dispatch "$cmd" "$@"; then
        exit "${_CVM_PLUGIN_RC:-0}"
      fi
      err "Unknown command: $cmd"
      echo ""
      cmd_help
      exit 1
      ;;
  esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
