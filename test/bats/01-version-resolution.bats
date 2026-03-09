#!/usr/bin/env bats
# Tests for version resolution order:
#   1. $CVM_VERSION env var
#   2. .claude-version file (walk up directory tree)
#   3. ~/.cvm/version global default

load "../helpers/common"

@test "no version source returns 'none'" {
  run bash "$CVM_SCRIPT" current
  # exits 1 and prints "none" when nothing configured
  assert_contains "none"
}

@test "CVM_VERSION env var is used" {
  make_fake_version "2.1.58"
  CVM_VERSION="2.1.58" run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.58" ]
}

@test "global default file is used" {
  set_global_default "2.1.66"
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.66" ]
}

@test ".claude-version in cwd is used" {
  make_fake_version "2.1.58"
  echo "2.1.58" > "$TEST_WORKDIR/.claude-version"
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.58" ]
}

@test ".claude-version with whitespace is trimmed" {
  make_fake_version "2.1.58"
  printf '  2.1.58  \n' > "$TEST_WORKDIR/.claude-version"
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.58" ]
}

@test ".claude-version in parent directory is found (walk-up)" {
  make_fake_version "2.1.55"
  echo "2.1.55" > "$TEST_WORKDIR/.claude-version"
  # create a subdirectory and run from there
  mkdir -p "$TEST_WORKDIR/sub/project"
  cd "$TEST_WORKDIR/sub/project"
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.55" ]
}

@test ".claude-version in grandparent is found (deeper walk-up)" {
  make_fake_version "2.1.55"
  echo "2.1.55" > "$TEST_WORKDIR/.claude-version"
  mkdir -p "$TEST_WORKDIR/a/b/c"
  cd "$TEST_WORKDIR/a/b/c"
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.55" ]
}

@test "closer .claude-version takes precedence over parent" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.71"
  echo "2.1.55" > "$TEST_WORKDIR/.claude-version"
  mkdir -p "$TEST_WORKDIR/child"
  echo "2.1.71" > "$TEST_WORKDIR/child/.claude-version"
  cd "$TEST_WORKDIR/child"
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.71" ]
}

@test "CVM_VERSION env overrides .claude-version" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.71"
  echo "2.1.55" > "$TEST_WORKDIR/.claude-version"
  CVM_VERSION="2.1.71" run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.71" ]
}

@test "CVM_VERSION env overrides global default" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.71"
  echo "2.1.55" > "$CVM_DIR/version"
  CVM_VERSION="2.1.71" run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.71" ]
}

@test ".claude-version takes precedence over global default" {
  make_fake_version "2.1.55"
  make_fake_version "2.1.71"
  echo "2.1.55" > "$CVM_DIR/version"
  echo "2.1.71" > "$TEST_WORKDIR/.claude-version"
  run bash "$CVM_SCRIPT" current
  assert_success
  [ "$output" = "2.1.71" ]
}
