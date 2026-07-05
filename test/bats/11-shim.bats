#!/usr/bin/env bats
# Tests for the active-`claude` wrapper shim: version resolution + env.d hooks.

load "../helpers/common"

# Install the wrapper for a given version (uses the real cvm use path).
install_wrapper() {
  make_fake_version "$1"
  bash "$CVM_SCRIPT" use "$1" >/dev/null
}

@test "wrapper execs the global default version" {
  install_wrapper "2.1.71"
  run "$CVM_DIR/bin/claude" --version
  assert_success
  assert_contains "Claude Code mock v2.1.71"
}

@test "wrapper respects .claude-version (per-directory)" {
  install_wrapper "2.1.58"
  make_fake_version "2.1.71"
  echo "2.1.71" > "$TEST_WORKDIR/.claude-version"

  run "$CVM_DIR/bin/claude"
  assert_success
  assert_contains "Claude Code mock v2.1.71"
}

@test "wrapper respects CVM_VERSION env over .claude-version" {
  install_wrapper "2.1.58"
  make_fake_version "2.1.71"
  make_fake_version "2.1.66"
  echo "2.1.71" > "$TEST_WORKDIR/.claude-version"

  CVM_VERSION="2.1.66" run "$CVM_DIR/bin/claude"
  assert_success
  assert_contains "Claude Code mock v2.1.66"
}

@test "wrapper sources ~/.cvm/env.d/*.sh before exec'ing the binary" {
  install_wrapper "2.1.71"
  mkdir -p "$CVM_DIR/env.d"
  local marker; marker="$(mktemp)"
  rm -f "$marker"
  echo "touch '$marker'" > "$CVM_DIR/env.d/hook.sh"
  run "$CVM_DIR/bin/claude"
  assert_success
  [ -f "$marker" ]
}

@test "wrapper errors when no version is active" {
  install_wrapper "2.1.71"
  rm -f "$CVM_DIR/version"
  # Ensure no .claude-version walks up from the test workdir.
  run "$CVM_DIR/bin/claude"
  assert_failure
  assert_contains "no version active"
}

@test "wrapper errors when the active version is not installed" {
  install_wrapper "2.1.71"
  echo "9.9.99" > "$CVM_DIR/version"
  run "$CVM_DIR/bin/claude"
  assert_failure
  assert_contains "not installed"
}

@test "wrapper uses CVM_DIR env var, not the real ~/.cvm" {
  install_wrapper "2.1.71"
  # Run the wrapper from a different CWD with CVM_DIR exported (it already is).
  CVM_DIR="$CVM_DIR" run bash -c 'cd /tmp && "$0"' "$CVM_DIR/bin/claude"
  assert_success
  assert_contains "Claude Code mock v2.1.71"
}

# ── _refresh-shim ─────────────────────────────────────────────────────────────

@test "_refresh-shim regenerates an old symlink into the wrapper" {
  # Simulate a pre-0.2 install: bin/claude is a direct symlink to the binary.
  make_fake_version "2.1.71"
  mkdir -p "$CVM_DIR/bin"
  ln -sf "$CVM_DIR/versions/2.1.71/claude" "$CVM_DIR/bin/claude"
  echo "2.1.71" > "$CVM_DIR/version"
  [ -L "$CVM_DIR/bin/claude" ]

  run bash "$CVM_SCRIPT" _refresh-shim
  assert_success
  # Now it's a wrapper (regular bash file), not a symlink.
  [ -f "$CVM_DIR/bin/claude" ]
  [ ! -L "$CVM_DIR/bin/claude" ]
  head -1 "$CVM_DIR/bin/claude" | grep -q "bash"
  grep -q "env.d" "$CVM_DIR/bin/claude"
}

@test "_refresh-shim is a no-op when no version is active" {
  run bash "$CVM_SCRIPT" _refresh-shim
  assert_success
  [ ! -e "$CVM_DIR/bin/claude" ]
}
