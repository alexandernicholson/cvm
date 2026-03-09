#!/usr/bin/env bats
# Tests for cvm ls / cvm list / cvm ls-remote

load "../helpers/common"

# ── cvm ls ────────────────────────────────────────────────────────────────────

@test "ls with no versions installed shows helpful message" {
  run bash "$CVM_SCRIPT" ls
  assert_success
  assert_contains "No versions installed"
}

@test "ls with no versions installed suggests install" {
  run bash "$CVM_SCRIPT" ls
  assert_success
  assert_contains "install"
}

@test "ls shows installed version" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" ls
  assert_success
  assert_contains "2.1.71"
}

@test "ls shows multiple installed versions" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" ls
  assert_success
  assert_contains "2.1.55"
  assert_contains "2.1.58"
  assert_contains "2.1.71"
}

@test "ls marks active version with indicator" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.71"
  set_global_default "2.1.71"
  run bash "$CVM_SCRIPT" ls
  assert_success
  # Active version should have some kind of marker (arrow or indicator)
  echo "$output" | grep -q "2.1.71"
  echo "$output" | grep "2.1.71" | grep -qE "[→>*]|active"
}

@test "list is an alias for ls" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" list
  assert_success
  assert_contains "2.1.71"
}

@test "ls does not show uninstalled versions" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" ls
  assert_success
  assert_not_contains "2.1.55"
  assert_not_contains "2.1.58"
}

@test "ls after uninstall does not show removed version" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.71"
  set_global_default "2.1.55"

  bash "$CVM_SCRIPT" uninstall 2.1.71
  run bash "$CVM_SCRIPT" ls
  assert_success
  assert_not_contains "2.1.71"
  assert_contains "2.1.55"
}

# ── cvm ls-remote ─────────────────────────────────────────────────────────────

@test "ls-remote shows available versions" {
  run bash "$CVM_SCRIPT" ls-remote
  assert_success
  assert_contains "2.1.71"
  assert_contains "2.1.58"
}

@test "ls-remote marks the latest version" {
  run bash "$CVM_SCRIPT" ls-remote
  assert_success
  # "latest" label should appear next to 2.1.71
  echo "$output" | grep "2.1.71" | grep -qi "latest"
}

@test "ls-remote marks the stable version" {
  run bash "$CVM_SCRIPT" ls-remote
  assert_success
  # "stable" label should appear next to 2.1.58
  echo "$output" | grep "2.1.58" | grep -qi "stable"
}

@test "ls-remote without --all shows limited versions with hint" {
  run bash "$CVM_SCRIPT" ls-remote
  assert_success
  # Should mention --all flag
  assert_contains "all"
}

@test "ls-remote --all shows all versions" {
  run bash "$CVM_SCRIPT" ls-remote --all
  assert_success
  assert_contains "2.1.55"
  assert_contains "2.1.56"
  assert_contains "2.1.58"
  assert_contains "2.1.66"
  assert_contains "2.1.71"
}

@test "list-remote is an alias for ls-remote" {
  run bash "$CVM_SCRIPT" list-remote
  assert_success
  assert_contains "2.1.71"
}
