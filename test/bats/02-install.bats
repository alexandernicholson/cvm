#!/usr/bin/env bats
# Tests for cvm install

load "../helpers/common"

@test "install specific version succeeds" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  assert_contains "Installed Claude Code 2.1.71"
}

@test "install places binary in correct location" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  [ -f "$CVM_DIR/versions/2.1.71/claude" ]
}

@test "install makes binary executable" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  [ -x "$CVM_DIR/versions/2.1.71/claude" ]
}

@test "install creates bin wrapper when first install" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  # Wrapper is a regular bash file (not a symlink) and is executable.
  [ -f "$CVM_DIR/bin/claude" ]
  [ ! -L "$CVM_DIR/bin/claude" ]
  [ -x "$CVM_DIR/bin/claude" ]
  head -1 "$CVM_DIR/bin/claude" | grep -q "bash"
}

@test "install wrapper sources env.d and execs the installed binary" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  # Drop an env hook and confirm the wrapper sources it, then execs the binary.
  mkdir -p "$CVM_DIR/env.d"
  local marker; marker="$(mktemp)"
  rm -f "$marker"
  echo "touch '$marker'" > "$CVM_DIR/env.d/test.sh"
  run "$CVM_DIR/bin/claude" --version
  assert_success
  assert_contains "Claude Code mock"
  [ -f "$marker" ]
}

@test "install sets global default when first install" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  [ -f "$CVM_DIR/version" ]
  default=$(cat "$CVM_DIR/version")
  [ "$default" = "2.1.71" ]
}

@test "install does not overwrite existing global default" {
  make_fake_version "2.1.58"
  echo "2.1.58" > "$CVM_DIR/version"
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  # default should still be 2.1.58
  default=$(cat "$CVM_DIR/version")
  [ "$default" = "2.1.58" ]
}

@test "install latest resolves to a version" {
  run bash "$CVM_SCRIPT" install latest
  assert_success
  assert_contains "Installed Claude Code"
  # The mock returns 2.1.71 for latest
  [ -d "$CVM_DIR/versions/2.1.71" ]
}

@test "install stable resolves to stable version" {
  run bash "$CVM_SCRIPT" install stable
  assert_success
  # The mock returns 2.1.58 for stable
  [ -d "$CVM_DIR/versions/2.1.58" ]
}

@test "install strips leading v from version" {
  run bash "$CVM_SCRIPT" install v2.1.71
  assert_success
  [ -d "$CVM_DIR/versions/2.1.71" ]
}

@test "install already-installed version is a no-op success" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  assert_contains "already installed"
}

@test "install fetches manifest URL" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  assert_curl_called_with "2.1.71/manifest.json"
}

@test "install fetches binary from correct URL pattern" {
  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  assert_curl_called_with "2.1.71"
  assert_curl_called_with "/claude"
}

@test "install fails for non-existent version" {
  # Mock curl returns 404 (exit 22) for unknown versions
  run bash "$CVM_SCRIPT" install 9.9.99
  assert_failure
}

@test "install fails when download fails" {
  MOCK_CURL_FAIL_BINARY=1 run bash "$CVM_SCRIPT" install 2.1.71
  assert_failure
  assert_contains "failed"
  # Binary should NOT be left behind (check both unix and windows binary names)
  [ ! -f "$CVM_DIR/versions/2.1.71/claude" ]
  [ ! -f "$CVM_DIR/versions/2.1.71/claude.exe" ]
}

@test "install cleans up temp file on checksum failure" {
  # Inject wrong checksum by making manifest return junk
  MOCK_CURL_FAIL="manifest.json" run bash "$CVM_SCRIPT" install 2.1.71
  assert_failure
  # No partial install
  [ ! -f "$CVM_DIR/versions/2.1.71/claude" ]
}

@test "install without args defaults to latest" {
  run bash "$CVM_SCRIPT" install
  assert_success
  [ -d "$CVM_DIR/versions/2.1.71" ]
}
