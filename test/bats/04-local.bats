#!/usr/bin/env bats
# Tests for cvm local (per-directory version pinning)

load "../helpers/common"

@test "local writes .claude-version in cwd" {
  make_fake_version "2.1.58"
  run bash "$CVM_SCRIPT" local 2.1.58
  assert_success
  [ -f "$TEST_WORKDIR/.claude-version" ]
}

@test "local writes correct version to .claude-version" {
  make_fake_version "2.1.58"
  run bash "$CVM_SCRIPT" local 2.1.58
  assert_success
  [ "$(cat "$TEST_WORKDIR/.claude-version")" = "2.1.58" ]
}

@test "local resolves latest channel to actual version" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" local latest
  assert_success
  # mock latest = 2.1.71
  [ "$(cat "$TEST_WORKDIR/.claude-version")" = "2.1.71" ]
}

@test "local resolves stable channel to actual version" {
  make_fake_version "2.1.58"
  run bash "$CVM_SCRIPT" local stable
  assert_success
  # mock stable = 2.1.58
  [ "$(cat "$TEST_WORKDIR/.claude-version")" = "2.1.58" ]
}

@test "local without arg exits non-zero with usage" {
  run bash "$CVM_SCRIPT" local
  assert_failure
  assert_contains "Usage"
}

@test "local warns when version is not installed" {
  # 2.1.99 is not in our mock known versions, but local should still write
  # the file (user may install later). However since 2.1.99 would fail
  # resolution through mock, let's use a known version that is just not installed.
  # We skip installation to test the warning path.
  run bash "$CVM_SCRIPT" local 2.1.55
  # Should succeed (writes file) but warn about not installed
  [ "$status" -eq 0 ]
  [ -f "$TEST_WORKDIR/.claude-version" ]
  assert_contains "warn"
}

@test "local overrides a previously written .claude-version" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.71"
  echo "2.1.55" > "$TEST_WORKDIR/.claude-version"

  run bash "$CVM_SCRIPT" local 2.1.71
  assert_success
  [ "$(cat "$TEST_WORKDIR/.claude-version")" = "2.1.71" ]
}

@test "local version is picked up by current" {
  make_fake_version "2.1.58"
  echo "2.1.58" > "$TEST_WORKDIR/.claude-version"

  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.58" ]
}

@test "local does not affect global default" {
  set_global_default "2.1.71"
  make_fake_version "2.1.58"
  run bash "$CVM_SCRIPT" local 2.1.58
  assert_success

  # Global default unchanged
  [ "$(cat "$CVM_DIR/version")" = "2.1.71" ]
}
