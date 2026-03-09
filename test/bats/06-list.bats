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

# ── ls-remote source resilience ───────────────────────────────────────────────

@test "ls-remote merges versions from both GitHub and npm" {
  # Mock: GitHub has 2.1.56-2.1.71 but NOT 2.1.55
  #       npm has 2.1.55-2.1.71
  # Combined should have 2.1.55 (npm-only) + the rest
  run bash "$CVM_SCRIPT" ls-remote --all
  assert_success
  assert_contains "2.1.55"
  assert_contains "2.1.71"
}

@test "ls-remote deduplicates versions present in both sources" {
  # 2.1.56, 2.1.58, 2.1.66, 2.1.71 appear in both GitHub and npm
  # They should appear exactly once in output
  run bash "$CVM_SCRIPT" ls-remote --all
  assert_success
  count=$(echo "$output" | grep -c "2.1.71")
  [ "$count" -eq 1 ]
}

@test "ls-remote works when GitHub is unavailable" {
  MOCK_CURL_FAIL_GITHUB=1 run bash "$CVM_SCRIPT" ls-remote --all
  assert_success
  assert_contains "2.1.71"
  assert_contains "2.1.55"
}

@test "ls-remote works when npm is unavailable" {
  MOCK_CURL_FAIL_NPM=1 run bash "$CVM_SCRIPT" ls-remote --all
  assert_success
  # GitHub mock has 2.1.56-2.1.71 (not 2.1.55)
  assert_contains "2.1.71"
  assert_contains "2.1.56"
}

@test "ls-remote npm-only version appears when GitHub is unavailable" {
  # 2.1.55 is only in npm mock; if GitHub is down it must still appear
  MOCK_CURL_FAIL_GITHUB=1 run bash "$CVM_SCRIPT" ls-remote --all
  assert_success
  assert_contains "2.1.55"
}

@test "ls-remote github-only version would appear when npm is unavailable" {
  # With only GitHub available, 2.1.56 (GitHub-only relative to npm) still shows
  MOCK_CURL_FAIL_NPM=1 run bash "$CVM_SCRIPT" ls-remote --all
  assert_success
  assert_contains "2.1.56"
}

@test "ls-remote fails when both GitHub and npm are unavailable" {
  MOCK_CURL_FAIL_GITHUB=1 MOCK_CURL_FAIL_NPM=1 run bash "$CVM_SCRIPT" ls-remote --all
  assert_failure
  assert_contains "unavailable"
}

@test "ls-remote results are sorted correctly regardless of source order" {
  run bash "$CVM_SCRIPT" ls-remote --all
  assert_success
  # 2.1.55 must appear before 2.1.71
  line_55=$(echo "$output" | grep -n "2\.1\.55" | cut -d: -f1)
  line_71=$(echo "$output" | grep -n "2\.1\.71" | cut -d: -f1)
  [ "$line_55" -lt "$line_71" ]
}
