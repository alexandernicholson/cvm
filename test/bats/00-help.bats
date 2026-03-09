#!/usr/bin/env bats
# Tests for help, version, and unknown command handling

load "../helpers/common"

@test "cvm with no args shows help" {
  run bash "$CVM_SCRIPT"
  assert_success
  assert_contains "USAGE"
  assert_contains "install"
}

@test "cvm help shows usage" {
  run bash "$CVM_SCRIPT" help
  assert_success
  assert_contains "USAGE"
  assert_contains "install"
  assert_contains "use"
  assert_contains "ls-remote"
}

@test "cvm --help shows usage" {
  run bash "$CVM_SCRIPT" --help
  assert_success
  assert_contains "USAGE"
}

@test "cvm -h shows usage" {
  run bash "$CVM_SCRIPT" -h
  assert_success
  assert_contains "USAGE"
}

@test "cvm help documents version resolution order" {
  run bash "$CVM_SCRIPT" help
  assert_success
  assert_contains "CVM_VERSION"
  assert_contains ".claude-version"
}

@test "cvm help documents shell setup" {
  run bash "$CVM_SCRIPT" help
  assert_success
  assert_contains ".cvm/bin"
}

@test "cvm version prints version number" {
  run bash "$CVM_SCRIPT" version
  assert_success
  assert_contains "cvm "
  # Should match semver pattern
  echo "$output" | grep -qE "cvm [0-9]+\.[0-9]+\.[0-9]+"
}

@test "cvm --version prints version number" {
  run bash "$CVM_SCRIPT" --version
  assert_success
  echo "$output" | grep -qE "cvm [0-9]+\.[0-9]+\.[0-9]+"
}

@test "cvm -v prints version number" {
  run bash "$CVM_SCRIPT" -v
  assert_success
  echo "$output" | grep -qE "cvm [0-9]+\.[0-9]+\.[0-9]+"
}

@test "cvm unknown-command exits non-zero" {
  run bash "$CVM_SCRIPT" frobnicate
  assert_failure
  assert_contains "frobnicate"
}

@test "cvm unknown-command still shows help" {
  run bash "$CVM_SCRIPT" frobnicate
  [ "$status" -ne 0 ]
  assert_contains "USAGE"
}

@test "cvm env prints PATH export line" {
  run bash "$CVM_SCRIPT" env
  assert_success
  assert_contains ".cvm/bin"
  assert_contains "PATH"
}
