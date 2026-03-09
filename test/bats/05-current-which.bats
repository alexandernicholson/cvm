#!/usr/bin/env bats
# Tests for cvm current and cvm which

load "../helpers/common"

# ── cvm current ───────────────────────────────────────────────────────────────

@test "current with no config prints 'none'" {
  run bash "$CVM_SCRIPT" current
  assert_contains "none"
}

@test "current with global default prints that version" {
  set_global_default "2.1.66"
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.66" ]
}

@test "current with local .claude-version prints that version" {
  make_fake_version "2.1.58"
  echo "2.1.58" > "$TEST_WORKDIR/.claude-version"
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.58" ]
}

@test "current with CVM_VERSION env prints that version" {
  make_fake_version "2.1.55"
  CVM_VERSION="2.1.55" run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.55" ]
}

@test "current respects resolution priority: env > local > global" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.55"
  echo "2.1.58" > "$TEST_WORKDIR/.claude-version"

  # local overrides global
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.58" ]

  # env overrides local
  CVM_VERSION="2.1.71" run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.71" ]
}

# ── cvm which ─────────────────────────────────────────────────────────────────

@test "which with no version exits non-zero" {
  run bash "$CVM_SCRIPT" which
  assert_failure
  assert_contains "No version active"
}

@test "which with global default prints path" {
  set_global_default "2.1.71"
  run bash "$CVM_SCRIPT" which
  assert_success
  assert_contains "2.1.71/claude"
}

@test "which path exists as a file" {
  set_global_default "2.1.71"
  run bash "$CVM_SCRIPT" which
  assert_success
  [ -f "$output" ]
}

@test "which path is executable" {
  set_global_default "2.1.71"
  run bash "$CVM_SCRIPT" which
  assert_success
  [ -x "$output" ]
}

@test "which respects CVM_VERSION env" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.71"
  set_global_default "2.1.55"

  CVM_VERSION="2.1.71" run bash "$CVM_SCRIPT" which
  assert_success
  assert_contains "2.1.71"
}

@test "which with version set but not installed exits non-zero" {
  echo "2.1.99" > "$CVM_DIR/version"
  run bash "$CVM_SCRIPT" which
  assert_failure
  assert_contains "not installed"
}

@test "which respects local .claude-version" {
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.58"
  echo "2.1.71" > "$TEST_WORKDIR/.claude-version"

  run bash "$CVM_SCRIPT" which
  assert_success
  assert_contains "2.1.71"
}
