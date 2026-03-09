#!/usr/bin/env bats
# Shell compatibility tests: bash, zsh, fish
#
# Structure:
#   Part 1 - cvm env shell detection (no extra shell required)
#   Part 2 - Syntax validation (skipped if shell not installed)
#   Part 3 - install.sh shell detection (no extra shell required)
#   Part 4 - Functional: cvm commands called FROM each shell
#   Part 5 - Full workflow in each shell

load "../helpers/common"

INSTALL_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/install.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Run cvm inside a given shell process.
# Usage: run_in_shell <shell-binary> <cvm-args...>
run_in_shell() {
  local shell_bin="$1"; shift
  "$shell_bin" -c "
    export PATH='${CVM_HELPERS_BIN}:${PATH}'
    export CVM_DIR='${CVM_DIR}'
    export CURL_LOG='${CURL_LOG}'
    bash '${CVM_SCRIPT}' $*
  "
}

# ═══════════════════════════════════════════════════════════════════════════════
# Part 1 — cvm env shell detection (no extra shell required)
# ═══════════════════════════════════════════════════════════════════════════════

@test "env: SHELL=bash emits export PATH syntax" {
  SHELL=/bin/bash run bash "$CVM_SCRIPT" env
  assert_success
  assert_contains "export PATH"
  assert_not_contains "fish_add_path"
}

@test "env: SHELL=zsh emits export PATH syntax" {
  SHELL=/bin/zsh run bash "$CVM_SCRIPT" env
  assert_success
  assert_contains "export PATH"
  assert_not_contains "fish_add_path"
}

@test "env: SHELL=/usr/bin/fish emits fish_add_path syntax" {
  SHELL=/usr/bin/fish run bash "$CVM_SCRIPT" env
  assert_success
  assert_contains "fish_add_path"
  assert_not_contains "export PATH"
}

@test "env: SHELL=/opt/homebrew/bin/fish emits fish_add_path syntax" {
  SHELL=/opt/homebrew/bin/fish run bash "$CVM_SCRIPT" env
  assert_success
  assert_contains "fish_add_path"
  assert_not_contains "export PATH"
}

@test "env: --bash flag emits export PATH syntax" {
  run bash "$CVM_SCRIPT" env --bash
  assert_success
  assert_contains "export PATH"
  assert_not_contains "fish_add_path"
}

@test "env: --zsh flag emits export PATH syntax" {
  run bash "$CVM_SCRIPT" env --zsh
  assert_success
  assert_contains "export PATH"
  assert_not_contains "fish_add_path"
}

@test "env: --fish flag emits fish_add_path syntax" {
  run bash "$CVM_SCRIPT" env --fish
  assert_success
  assert_contains "fish_add_path"
  assert_not_contains "export PATH"
}

@test "env: bare shell name 'fish' works as flag" {
  run bash "$CVM_SCRIPT" env fish
  assert_success
  assert_contains "fish_add_path"
}

@test "env: bare shell name 'bash' works as flag" {
  run bash "$CVM_SCRIPT" env bash
  assert_success
  assert_contains "export PATH"
}

@test "env: bare shell name 'zsh' works as flag" {
  run bash "$CVM_SCRIPT" env zsh
  assert_success
  assert_contains "export PATH"
}

@test "env: unknown shell flag exits non-zero" {
  run bash "$CVM_SCRIPT" env --powershell
  assert_failure
  assert_contains "Supported"
}

@test "env --bash output contains CVM_DIR bin path" {
  run bash "$CVM_SCRIPT" env --bash
  assert_success
  assert_contains "$CVM_DIR/bin"
}

@test "env --fish output contains CVM_DIR bin path" {
  run bash "$CVM_SCRIPT" env --fish
  assert_success
  assert_contains "$CVM_DIR/bin"
}

@test "env --fish output uses fish_add_path not set -x PATH" {
  run bash "$CVM_SCRIPT" env --fish
  assert_success
  # fish_add_path is the modern idiomatic fish approach
  assert_contains "fish_add_path"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Part 2 — Syntax validation (skipped if shell not installed)
# ═══════════════════════════════════════════════════════════════════════════════

@test "syntax: env --bash output is valid bash" {
  local line
  line=$(bash "$CVM_SCRIPT" env --bash)
  run bash -c "$line; echo ok"
  assert_success
}

@test "syntax: env --zsh output is valid zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  local line
  line=$(bash "$CVM_SCRIPT" env --zsh)
  run zsh -c "$line; echo ok"
  assert_success
}

@test "syntax: env --fish output is valid fish syntax" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  local line
  line=$(bash "$CVM_SCRIPT" env --fish)
  # fish --no-execute (-n) checks syntax without running
  run fish -c "$line; echo ok"
  assert_success
}

@test "syntax: env --sh output is valid sh" {
  run bash "$CVM_SCRIPT" env --sh
  assert_success
  local line="$output"
  run sh -c "$line; echo ok"
  assert_success
}

# ═══════════════════════════════════════════════════════════════════════════════
# Part 3 — install.sh shell detection (no extra shell required)
# ═══════════════════════════════════════════════════════════════════════════════

@test "install.sh: SHELL=bash shows export PATH in output" {
  run bash -c "echo n | SHELL=/bin/bash CVM_DIR='$CVM_DIR' PATH='$CVM_HELPERS_BIN:$PATH' bash '$INSTALL_SCRIPT'"
  assert_contains "export PATH"
  assert_not_contains "fish_add_path"
}

@test "install.sh: SHELL=zsh shows export PATH in output" {
  run bash -c "echo n | SHELL=/bin/zsh CVM_DIR='$CVM_DIR' PATH='$CVM_HELPERS_BIN:$PATH' bash '$INSTALL_SCRIPT'"
  assert_contains "export PATH"
  assert_not_contains "fish_add_path"
}

@test "install.sh: SHELL=fish shows fish_add_path in output" {
  run bash -c "echo n | SHELL=/usr/bin/fish CVM_DIR='$CVM_DIR' PATH='$CVM_HELPERS_BIN:$PATH' bash '$INSTALL_SCRIPT'"
  assert_contains "fish_add_path"
  assert_not_contains "export PATH"
}

@test "install.sh: SHELL=/opt/homebrew/bin/fish shows fish_add_path in output" {
  run bash -c "echo n | SHELL=/opt/homebrew/bin/fish CVM_DIR='$CVM_DIR' PATH='$CVM_HELPERS_BIN:$PATH' bash '$INSTALL_SCRIPT'"
  assert_contains "fish_add_path"
}

@test "install.sh: SHELL=fish writes fish_add_path to config file" {
  local fake_home
  fake_home=$(mktemp -d)
  mkdir -p "$fake_home/.config/fish"
  touch "$fake_home/.config/fish/config.fish"

  run bash -c "echo y | HOME='$fake_home' SHELL=/usr/bin/fish CVM_DIR='$CVM_DIR' PATH='$CVM_HELPERS_BIN:$PATH' bash '$INSTALL_SCRIPT'"
  grep -q "fish_add_path" "$fake_home/.config/fish/config.fish"
  grep -vq "export PATH" "$fake_home/.config/fish/config.fish"
  rm -rf "$fake_home"
}

@test "install.sh: SHELL=zsh writes export PATH to .zshrc" {
  local fake_home
  fake_home=$(mktemp -d)
  touch "$fake_home/.zshrc"

  run bash -c "echo y | HOME='$fake_home' SHELL=/bin/zsh CVM_DIR='$CVM_DIR' PATH='$CVM_HELPERS_BIN:$PATH' bash '$INSTALL_SCRIPT'"
  grep -q "export PATH" "$fake_home/.zshrc"
  grep -vq "fish_add_path" "$fake_home/.zshrc"
  rm -rf "$fake_home"
}

@test "install.sh: SHELL=bash writes export PATH to .bashrc" {
  local fake_home
  fake_home=$(mktemp -d)
  touch "$fake_home/.bashrc"

  run bash -c "echo y | HOME='$fake_home' SHELL=/bin/bash CVM_DIR='$CVM_DIR' PATH='$CVM_HELPERS_BIN:$PATH' bash '$INSTALL_SCRIPT'"
  grep -q "export PATH" "$fake_home/.bashrc"
  rm -rf "$fake_home"
}

@test "install.sh: fish reload hint mentions fish config" {
  run bash -c "echo n | SHELL=/usr/bin/fish CVM_DIR='$CVM_DIR' PATH='$CVM_HELPERS_BIN:$PATH' bash '$INSTALL_SCRIPT'"
  # Should mention fish config or new terminal for reload
  assert_contains "fish"
}

@test "install.sh: zsh reload hint mentions .zshrc" {
  run bash -c "echo n | SHELL=/bin/zsh CVM_DIR='$CVM_DIR' PATH='$CVM_HELPERS_BIN:$PATH' bash '$INSTALL_SCRIPT'"
  assert_contains ".zshrc"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Part 4 — Functional: cvm commands called FROM each shell
# ═══════════════════════════════════════════════════════════════════════════════

# bash ── (reference; always runs)

@test "bash: cvm current works" {
  set_global_default "2.1.71"
  run bash -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' current"
  assert_success
  [ "$output" = "2.1.71" ]
}

@test "bash: cvm install works" {
  run bash -c "PATH='$CVM_HELPERS_BIN:$PATH' CVM_DIR='$CVM_DIR' CURL_LOG='$CURL_LOG' bash '$CVM_SCRIPT' install 2.1.71"
  assert_success
  [ -f "$CVM_DIR/versions/2.1.71/claude" ]
}

@test "bash: cvm which works" {
  set_global_default "2.1.71"
  run bash -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' which"
  assert_success
  assert_contains "2.1.71/claude"
}

@test "bash: claude symlink is executable from bash" {
  set_global_default "2.1.71"
  run bash -c "$CVM_DIR/bin/claude"
  assert_success
}

# zsh ─────────────────────────────────────────────────────────────────────────

@test "zsh: cvm current works" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  set_global_default "2.1.71"
  run zsh -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' current"
  assert_success
  [ "$output" = "2.1.71" ]
}

@test "zsh: cvm install works" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  run zsh -c "PATH='$CVM_HELPERS_BIN:$PATH' CVM_DIR='$CVM_DIR' CURL_LOG='$CURL_LOG' bash '$CVM_SCRIPT' install 2.1.71"
  assert_success
  [ -f "$CVM_DIR/versions/2.1.71/claude" ]
}

@test "zsh: cvm use works" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.58"
  run zsh -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' use 2.1.71"
  assert_success
  [ "$(cat "$CVM_DIR/version")" = "2.1.71" ]
}

@test "zsh: cvm ls works" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_fake_version "2.1.71"
  run zsh -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' ls"
  assert_success
  assert_contains "2.1.71"
}

@test "zsh: cvm which works" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  set_global_default "2.1.71"
  run zsh -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' which"
  assert_success
  assert_contains "2.1.71/claude"
}

@test "zsh: claude symlink is executable from zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  set_global_default "2.1.71"
  run zsh -c "$CVM_DIR/bin/claude"
  assert_success
}

@test "zsh: .claude-version file is respected" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.58"
  echo "2.1.71" > "$TEST_WORKDIR/.claude-version"
  run zsh -c "cd '$TEST_WORKDIR' && CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' current"
  assert_success
  [ "$output" = "2.1.71" ]
}

# fish ────────────────────────────────────────────────────────────────────────

@test "fish: cvm current works" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  set_global_default "2.1.71"
  run fish -c "set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' current"
  assert_success
  [ "$output" = "2.1.71" ]
}

@test "fish: cvm install works" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  run fish -c "set -x PATH '$CVM_HELPERS_BIN' \$PATH; set -x CVM_DIR '$CVM_DIR'; set -x CURL_LOG '$CURL_LOG'; bash '$CVM_SCRIPT' install 2.1.71"
  assert_success
  [ -f "$CVM_DIR/versions/2.1.71/claude" ]
}

@test "fish: cvm use works" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.58"
  run fish -c "set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' use 2.1.71"
  assert_success
  [ "$(cat "$CVM_DIR/version")" = "2.1.71" ]
}

@test "fish: cvm ls works" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  make_fake_version "2.1.71"
  run fish -c "set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' ls"
  assert_success
  assert_contains "2.1.71"
}

@test "fish: cvm which works" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  set_global_default "2.1.71"
  run fish -c "set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' which"
  assert_success
  assert_contains "2.1.71/claude"
}

@test "fish: cvm local works" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  make_fake_version "2.1.71"
  run fish -c "cd '$TEST_WORKDIR'; set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' local 2.1.71"
  assert_success
  [ "$(cat "$TEST_WORKDIR/.claude-version")" = "2.1.71" ]
}

@test "fish: cvm uninstall works" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  make_fake_version "2.1.71"
  run fish -c "set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' uninstall 2.1.71"
  assert_success
  [ ! -d "$CVM_DIR/versions/2.1.71" ]
}

@test "fish: claude symlink is executable from fish" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  set_global_default "2.1.71"
  run fish -c "$CVM_DIR/bin/claude"
  assert_success
}

@test "fish: .claude-version file is respected" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  make_fake_version "2.1.58"
  make_fake_version "2.1.71"
  set_global_default "2.1.58"
  echo "2.1.71" > "$TEST_WORKDIR/.claude-version"
  run fish -c "cd '$TEST_WORKDIR'; set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' current"
  assert_success
  [ "$output" = "2.1.71" ]
}

@test "fish: CVM_VERSION env var is respected" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"
  make_fake_version "2.1.55"
  make_fake_version "2.1.71"
  set_global_default "2.1.55"
  run fish -c "set -x CVM_DIR '$CVM_DIR'; set -x CVM_VERSION '2.1.71'; bash '$CVM_SCRIPT' current"
  assert_success
  [ "$output" = "2.1.71" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Part 5 — Full install→use→current→which workflow per shell
# ═══════════════════════════════════════════════════════════════════════════════

@test "bash: full workflow install→use→current→which" {
  bash -c "PATH='$CVM_HELPERS_BIN:$PATH' CVM_DIR='$CVM_DIR' CURL_LOG='$CURL_LOG' bash '$CVM_SCRIPT' install 2.1.71"
  bash -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' use 2.1.71"

  run bash -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' current"
  assert_success
  [ "$output" = "2.1.71" ]

  run bash -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' which"
  assert_success
  [ -f "$output" ]
}

@test "zsh: full workflow install→use→current→which" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"

  zsh -c "PATH='$CVM_HELPERS_BIN:$PATH' CVM_DIR='$CVM_DIR' CURL_LOG='$CURL_LOG' bash '$CVM_SCRIPT' install 2.1.71"
  zsh -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' use 2.1.71"

  run zsh -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' current"
  assert_success
  [ "$output" = "2.1.71" ]

  run zsh -c "CVM_DIR='$CVM_DIR' bash '$CVM_SCRIPT' which"
  assert_success
  [ -f "$output" ]
}

@test "fish: full workflow install→use→current→which" {
  command -v fish >/dev/null 2>&1 || skip "fish not installed"

  fish -c "set -x PATH '$CVM_HELPERS_BIN' \$PATH; set -x CVM_DIR '$CVM_DIR'; set -x CURL_LOG '$CURL_LOG'; bash '$CVM_SCRIPT' install 2.1.71"
  fish -c "set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' use 2.1.71"

  run fish -c "set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' current"
  assert_success
  [ "$output" = "2.1.71" ]

  run fish -c "set -x CVM_DIR '$CVM_DIR'; bash '$CVM_SCRIPT' which"
  assert_success
  [ -f "$output" ]
}
