#!/usr/bin/env bats
# Tests for cvm uninstall

load "../helpers/common"

@test "uninstall removes version directory" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" uninstall 2.1.71
  assert_success
  [ ! -d "$CVM_DIR/versions/2.1.71" ]
}

@test "uninstall prints confirmation" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" uninstall 2.1.71
  assert_success
  assert_contains "2.1.71"
}

@test "uninstall without args exits non-zero with usage" {
  run bash "$CVM_SCRIPT" uninstall
  assert_failure
  assert_contains "Usage"
}

@test "uninstall non-installed version exits non-zero" {
  run bash "$CVM_SCRIPT" uninstall 9.9.99
  assert_failure
  assert_contains "not installed"
}

@test "uninstall active version clears symlink" {
  set_global_default "2.1.71"
  run bash "$CVM_SCRIPT" uninstall 2.1.71
  assert_success
  [ ! -L "$CVM_DIR/bin/claude" ]
}

@test "uninstall active version clears global default file" {
  set_global_default "2.1.71"
  run bash "$CVM_SCRIPT" uninstall 2.1.71
  assert_success
  [ ! -f "$CVM_DIR/version" ]
}

@test "uninstall active version warns user" {
  set_global_default "2.1.71"
  run bash "$CVM_SCRIPT" uninstall 2.1.71
  assert_success
  assert_contains "warn"
}

@test "uninstall active version suggests setting new version" {
  set_global_default "2.1.71"
  run bash "$CVM_SCRIPT" uninstall 2.1.71
  assert_success
  assert_contains "use"
}

@test "uninstall non-active version preserves symlink" {
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.71"

  run bash "$CVM_SCRIPT" uninstall 2.1.58
  assert_success

  [ -L "$CVM_DIR/bin/claude" ]
  link_target=$(readlink "$CVM_DIR/bin/claude")
  [[ "$link_target" == *"2.1.71/claude" ]]
}

@test "uninstall non-active version preserves global default" {
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.71"

  run bash "$CVM_SCRIPT" uninstall 2.1.58
  assert_success

  [ "$(cat "$CVM_DIR/version")" = "2.1.71" ]
}

@test "remove is an alias for uninstall" {
  make_fake_version "2.1.71"
  run bash "$CVM_SCRIPT" remove 2.1.71
  assert_success
  [ ! -d "$CVM_DIR/versions/2.1.71" ]
}

@test "can reinstall after uninstall" {
  make_fake_version "2.1.71"
  bash "$CVM_SCRIPT" uninstall 2.1.71
  [ ! -d "$CVM_DIR/versions/2.1.71" ]

  run bash "$CVM_SCRIPT" install 2.1.71
  assert_success
  [ -d "$CVM_DIR/versions/2.1.71" ]
}
