# Common setup/teardown and helpers for CVM bats tests

# Path to cvm.sh (test/bats/ -> test/ -> repo root)
CVM_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/cvm.sh"
CVM_HELPERS_BIN="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)/helpers/bin"

setup() {
  # Isolated install dir per test
  export CVM_DIR
  CVM_DIR=$(mktemp -d)

  # Inject mock curl before any real curl in PATH
  export PATH="${CVM_HELPERS_BIN}:${PATH}"

  # Log file for inspecting which URLs curl was called with
  export CURL_LOG
  CURL_LOG=$(mktemp)

  # Working directory for each test (prevents leaking .claude-version files)
  export TEST_WORKDIR
  TEST_WORKDIR=$(mktemp -d)
  cd "$TEST_WORKDIR"
}

teardown() {
  rm -rf "${CVM_DIR:-}"
  rm -f  "${CURL_LOG:-}"
  rm -rf "${TEST_WORKDIR:-}"
}

# ── Test helpers ──────────────────────────────────────────────────────────────

# Pre-populate a fake installed version, bypassing the install command.
make_fake_version() {
  local version="$1"
  mkdir -p "$CVM_DIR/versions/$version"
  printf '#!/usr/bin/env bash\necho "Claude Code mock v%s"\n' "$version" \
    > "$CVM_DIR/versions/$version/claude"
  chmod +x "$CVM_DIR/versions/$version/claude"
}

# Set a version as the active global default (updates symlink + default file).
set_global_default() {
  local version="$1"
  make_fake_version "$version"
  mkdir -p "$CVM_DIR/bin"
  ln -sf "$CVM_DIR/versions/$version/claude" "$CVM_DIR/bin/claude"
  echo "$version" > "$CVM_DIR/version"
}

# Assert output contains a substring.
assert_contains() {
  local needle="$1"
  if ! echo "$output" | grep -qF "$needle"; then
    echo "Expected output to contain: $needle"
    echo "Actual output: $output"
    return 1
  fi
}

# Assert output does NOT contain a substring.
assert_not_contains() {
  local needle="$1"
  if echo "$output" | grep -qF "$needle"; then
    echo "Expected output NOT to contain: $needle"
    echo "Actual output: $output"
    return 1
  fi
}

# Assert exit status is success (0).
assert_success() {
  if [[ "$status" -ne 0 ]]; then
    echo "Expected exit 0, got $status"
    echo "Output: $output"
    return 1
  fi
}

# Assert exit status is failure (non-zero).
assert_failure() {
  if [[ "$status" -eq 0 ]]; then
    echo "Expected non-zero exit, got 0"
    echo "Output: $output"
    return 1
  fi
}

# Assert CURL_LOG contains a URL matching a pattern.
assert_curl_called_with() {
  local pattern="$1"
  if ! grep -qF "$pattern" "$CURL_LOG" 2>/dev/null; then
    echo "Expected curl to be called with URL containing: $pattern"
    echo "Curl log: $(cat "$CURL_LOG" 2>/dev/null || echo '(empty)')"
    return 1
  fi
}
