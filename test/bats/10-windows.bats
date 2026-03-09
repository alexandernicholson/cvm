#!/usr/bin/env bats
# Tests for Windows (MINGW64/Git Bash) platform support.
# These tests run on all host platforms: a mock uname injects MINGW64 values
# so we can exercise the Windows-specific code paths without needing Windows.

load "../helpers/common"

# ── Windows-specific setup ────────────────────────────────────────────────────
# Override the common setup: prepend windows-bin (fake uname) before helpers.

WIN_BIN="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)/helpers/windows-bin"

setup() {
  export CVM_DIR
  CVM_DIR=$(mktemp -d)

  # Windows mock uname must come first so both cvm.sh and mock curl see it
  export PATH="${WIN_BIN}:${CVM_HELPERS_BIN}:${PATH}"

  export CURL_LOG
  CURL_LOG=$(mktemp)

  export TEST_WORKDIR
  TEST_WORKDIR=$(mktemp -d)
  cd "$TEST_WORKDIR"

  # Track WIN_BIN_TMP for teardown (not the shared WIN_BIN dir)
  export WIN_BIN_TMP=""
}

teardown() {
  rm -rf "${CVM_DIR:-}"
  rm -f  "${CURL_LOG:-}"
  rm -rf "${TEST_WORKDIR:-}"
}

# Helper: create a fake installed version with .exe binary name
make_fake_win_version() {
  local version="$1"
  mkdir -p "$CVM_DIR/versions/$version"
  printf '#!/usr/bin/env bash\necho "Claude Code mock v%s"\n' "$version" \
    > "$CVM_DIR/versions/$version/claude.exe"
  chmod +x "$CVM_DIR/versions/$version/claude.exe"
}

# Helper: set a Windows version as active global default
set_win_global_default() {
  local version="$1"
  make_fake_win_version "$version"
  mkdir -p "$CVM_DIR/bin"
  ln -sf "$CVM_DIR/versions/$version/claude.exe" "$CVM_DIR/bin/claude.exe"
  echo "$version" > "$CVM_DIR/version"
}

# ── Platform detection ────────────────────────────────────────────────────────

@test "detect_platform returns win32-x64 on MINGW64" {
  # Run cvm with a command that triggers detect_platform (install triggers it)
  # We use 'cvm env' which does NOT call detect_platform — instead use
  # a tiny inline test via bash -c
  run bash -c "
    source \"$CVM_SCRIPT\" 2>/dev/null || true
    detect_platform
  "
  # Note: BASH_SOURCE guard prevents main from running on source — but
  # the guard checks BASH_SOURCE[0] == \$0, so sourcing is fine.
  assert_success
  assert_contains "win32-x64"
}

@test "cvm version still works under Windows mock" {
  run bash "$CVM_SCRIPT" version
  assert_success
  assert_contains "cvm"
}

@test "cvm env --pwsh outputs PowerShell PATH line" {
  run bash "$CVM_SCRIPT" env --pwsh
  assert_success
  assert_contains '$env:PATH'
  assert_contains "$CVM_DIR"
}

@test "cvm env --powershell outputs PowerShell PATH line" {
  run bash "$CVM_SCRIPT" env --powershell
  assert_success
  assert_contains '$env:PATH'
}

# ── Install ───────────────────────────────────────────────────────────────────

@test "cvm install downloads claude.exe on Windows" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  assert_contains "Installed Claude Code 2.1.71"
  [[ -f "$CVM_DIR/versions/2.1.71/claude.exe" ]]
}

@test "cvm install does not create unix claude binary on Windows" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  # The unix binary name should NOT be created (only .exe)
  [[ ! -f "$CVM_DIR/versions/2.1.71/claude" ]]
}

@test "cvm install sets claude.exe as symlink target on Windows" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  [[ -f "$CVM_DIR/bin/claude.exe" ]]
}

@test "cvm install download URL contains claude.exe for Windows" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  assert_curl_called_with "win32-x64/claude.exe"
}

# ── Use ───────────────────────────────────────────────────────────────────────

@test "cvm use switches to claude.exe on Windows" {
  make_fake_win_version "2.1.58"
  make_fake_win_version "2.1.71"
  set_win_global_default "2.1.58"

  run bash "$CVM_SCRIPT" use 2.1.71
  assert_success
  assert_contains "Now using Claude Code 2.1.71"
  [[ -f "$CVM_DIR/bin/claude.exe" ]]
  [[ "$(cat "$CVM_DIR/version")" == "2.1.71" ]]
}

# ── Which ─────────────────────────────────────────────────────────────────────

@test "cvm which returns .exe path on Windows" {
  set_win_global_default "2.1.71"

  run bash "$CVM_SCRIPT" which
  assert_success
  assert_contains "claude.exe"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────

@test "cvm uninstall removes Windows version directory" {
  make_fake_win_version "2.1.58"
  make_fake_win_version "2.1.71"
  set_win_global_default "2.1.58"

  run bash "$CVM_SCRIPT" uninstall 2.1.71
  assert_success
  assert_contains "Uninstalled"
  [[ ! -d "$CVM_DIR/versions/2.1.71" ]]
}

# ── List ──────────────────────────────────────────────────────────────────────

@test "cvm ls shows Windows-installed versions" {
  make_fake_win_version "2.1.58"
  make_fake_win_version "2.1.71"
  set_win_global_default "2.1.71"

  run bash "$CVM_SCRIPT" ls
  assert_success
  assert_contains "2.1.58"
  assert_contains "2.1.71"
}
