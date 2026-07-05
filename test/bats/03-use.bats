#!/usr/bin/env bats
# Tests for cvm use / cvm default

load "../helpers/common"

@test "use installs wrapper that execs the specified version" {
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.58"

  run bash "$CVM_SCRIPT" use 2.1.71
  assert_success

  # Wrapper is a regular file (not a symlink) and execs the 2.1.71 binary.
  [ -f "$CVM_DIR/bin/claude" ]
  [ ! -L "$CVM_DIR/bin/claude" ]
  run "$CVM_DIR/bin/claude"
  assert_success
  assert_contains "Claude Code mock v2.1.71"
}

@test "use updates global default file" {
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.58"

  run bash "$CVM_SCRIPT" use 2.1.71
  assert_success

  default=$(cat "$CVM_DIR/version")
  [ "$default" = "2.1.71" ]
}

@test "use prints confirmation message" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" use 2.1.71
  assert_success
  assert_contains "2.1.71"
  assert_contains "global"
}

@test "use without args exits non-zero with usage" {
  run bash "$CVM_SCRIPT" use
  assert_failure
  assert_contains "Usage"
}

@test "use non-installed version exits non-zero" {
  run bash "$CVM_SCRIPT" use 9.9.99
  assert_failure
  assert_contains "not installed"
}

@test "use non-installed version suggests install" {
  run bash "$CVM_SCRIPT" use 9.9.99
  assert_failure
  assert_contains "install"
}

@test "use latest resolves channel to version number" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" use latest
  assert_success
  default=$(cat "$CVM_DIR/version")
  [ "$default" = "2.1.71" ]
}

@test "default is an alias for use" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" default 2.1.71
  assert_success
  [ -f "$CVM_DIR/bin/claude" ]
  run "$CVM_DIR/bin/claude"
  assert_success
  assert_contains "Claude Code mock v2.1.71"
}

@test "use can switch between multiple installed versions" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.55"

  run bash "$CVM_SCRIPT" use 2.1.71
  assert_success
  [ "$(cat "$CVM_DIR/version")" = "2.1.71" ]

  run bash "$CVM_SCRIPT" use 2.1.58
  assert_success
  [ "$(cat "$CVM_DIR/version")" = "2.1.58" ]
}

@test "current reflects version after use" {
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.58"

  bash "$CVM_SCRIPT" use 2.1.71
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.71" ]
}
