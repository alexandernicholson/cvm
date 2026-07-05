#!/usr/bin/env bats
# Tests for the plugin manager (install/list/uninstall/update + dispatch).

load "../helpers/common"

# Create a throwaway local git repo that is a valid cvm plugin registering $2.
# Uses a fixed dir name ($1) under a temp parent so the installed plugin dir is
# deterministic. Echoes the repo path. $1 = dir name, $2 = subcommand.
make_fixture_plugin() {
  local dir_name="$1" cmd="$2"
  local parent; parent="$(mktemp -d)"
  local repo="$parent/$dir_name"
  mkdir -p "$repo"
  cat > "$repo/plugin.sh" <<EOF
CVM_PLUGIN_NAME="$dir_name"
CVM_PLUGIN_COMMAND="$cmd"
CVM_PLUGIN_VERSION="0.0.1-fix"
CVM_PLUGIN_DESCRIPION="fixture plugin for tests"
cvm_plugin_main() {
  echo "fixture-plugin: $cmd got: \$*"
}
EOF
  git -C "$repo" init -q
  git -C "$repo" add plugin.sh
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm fixture
  echo "$repo"
}

# A plugin repo missing plugin.sh (invalid). Echoes repo path.
make_broken_plugin() {
  local parent; parent="$(mktemp -d)"
  local repo="$parent/broken"
  mkdir -p "$repo"
  echo "not a plugin" > "$repo/README.md"
  git -C "$repo" init -q
  git -C "$repo" add README.md
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm readme
  echo "$repo"
}

# ── install / list / uninstall ─────────────────────────────────────────────────

@test "plugin install clones a local git repo into ~/.cvm/plugins" {
  local repo; repo="$(make_fixture_plugin fixplg fixcmd)"
  run bash "$CVM_SCRIPT" plugin install "$repo"
  assert_success
  assert_contains "Installed plugin"
  [ -f "$CVM_DIR/plugins/fixplg/plugin.sh" ]
}

@test "plugin install rejects a repo without plugin.sh" {
  local repo; repo="$(make_broken_plugin)"
  run bash "$CVM_SCRIPT" plugin install "$repo"
  assert_failure
  assert_contains "no plugin.sh"
  [ ! -d "$CVM_DIR/plugins/broken" ]
}

@test "plugin install with no args prints usage" {
  run bash "$CVM_SCRIPT" plugin install
  assert_failure
  assert_contains "Usage"
}

@test "plugin install rejects an invalid source" {
  run bash "$CVM_SCRIPT" plugin install not-a-repo
  assert_failure
  assert_contains "Invalid plugin source"
}

@test "plugin list shows installed plugins and their command" {
  local repo; repo="$(make_fixture_plugin fixplg fixcmd)"
  bash "$CVM_SCRIPT" plugin install "$repo" >/dev/null

  run bash "$CVM_SCRIPT" plugin list
  assert_success
  assert_contains "fixplg"
  assert_contains "cvm fixcmd"
}

@test "plugin list with none installed says so" {
  run bash "$CVM_SCRIPT" plugin list
  assert_success
  assert_contains "No plugins installed"
}

@test "plugin uninstall removes the plugin directory" {
  local repo; repo="$(make_fixture_plugin fixplg fixcmd)"
  bash "$CVM_SCRIPT" plugin install "$repo" >/dev/null
  [ -d "$CVM_DIR/plugins/fixplg" ]

  run bash "$CVM_SCRIPT" plugin uninstall fixplg
  assert_success
  [ ! -d "$CVM_DIR/plugins/fixplg" ]
}

@test "plugin uninstall of unknown plugin fails" {
  run bash "$CVM_SCRIPT" plugin uninstall nope
  assert_failure
}

# ── subcommand dispatch ───────────────────────────────────────────────────────

@test "unknown top-level command dispatches to a matching plugin" {
  local repo; repo="$(make_fixture_plugin fixplg fixcmd)"
  bash "$CVM_SCRIPT" plugin install "$repo" >/dev/null

  run bash "$CVM_SCRIPT" fixcmd hello world
  assert_success
  assert_contains "fixture-plugin: fixcmd got: hello world"
}

@test "dispatch passes through the plugin exit code" {
  local parent; parent="$(mktemp -d)"
  local repo="$parent/exitplg"
  mkdir -p "$repo"
  cat > "$repo/plugin.sh" <<'EOF'
CVM_PLUGIN_NAME="exitplg"
CVM_PLUGIN_COMMAND="exitcmd"
CVM_PLUGIN_VERSION="0.0.1"
cvm_plugin_main() { echo "bye"; exit 42; }
EOF
  git -C "$repo" init -q
  git -C "$repo" add plugin.sh
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm x
  bash "$CVM_SCRIPT" plugin install "$repo" >/dev/null

  run bash "$CVM_SCRIPT" exitcmd
  [ "$status" -eq 42 ]
  assert_contains "bye"
}

@test "unknown command with no matching plugin prints Unknown command" {
  run bash "$CVM_SCRIPT" definitely-not-a-command
  assert_failure
  assert_contains "Unknown command"
}

@test "plugin with no args prints plugin help" {
  run bash "$CVM_SCRIPT" plugin
  assert_success
  assert_contains "manage cvm plugins"
}

# ── update ─────────────────────────────────────────────────────────────────────

@test "plugin update pulls from source" {
  local repo; repo="$(make_fixture_plugin fixplg fixcmd)"
  bash "$CVM_SCRIPT" plugin install "$repo" >/dev/null

  run bash "$CVM_SCRIPT" plugin update fixplg
  assert_success
  assert_contains "Updated plugin"
}

@test "plugin update of unknown plugin fails" {
  run bash "$CVM_SCRIPT" plugin update nope
  assert_failure
}

@test "plugin update --all updates every installed plugin" {
  local a b
  a="$(make_fixture_plugin plgA cmdA)"
  b="$(make_fixture_plugin plgB cmdB)"
  bash "$CVM_SCRIPT" plugin install "$a" >/dev/null
  bash "$CVM_SCRIPT" plugin install "$b" >/dev/null

  run bash "$CVM_SCRIPT" plugin update --all
  assert_success
  assert_contains "Updating plugin 'plgA'"
  assert_contains "Updating plugin 'plgB'"
}

@test "plugin update with no args updates all" {
  local a
  a="$(make_fixture_plugin plgC cmdC)"
  bash "$CVM_SCRIPT" plugin install "$a" >/dev/null

  run bash "$CVM_SCRIPT" plugin update
  assert_success
  assert_contains "Updating plugin 'plgC'"
}

@test "plugin update --all continues past a broken plugin" {
  local a
  a="$(make_fixture_plugin plgD cmdD)"
  bash "$CVM_SCRIPT" plugin install "$a" >/dev/null
  # Corrupt one plugin's git repo so pull fails.
  git -C "$CVM_DIR/plugins/plgD" remote remove origin 2>/dev/null || true

  run bash "$CVM_SCRIPT" plugin update --all
  assert_failure
  assert_contains "Failed to update 'plgD'"
}

# ── init hook ─────────────────────────────────────────────────────────────────

@test "install runs cvm_plugin_init if the plugin defines it" {
  local parent; parent="$(mktemp -d)"
  local repo="$parent/initplg"
  mkdir -p "$repo"
  cat > "$repo/plugin.sh" <<'EOF'
CVM_PLUGIN_NAME="initplg"
CVM_PLUGIN_COMMAND="initcmd"
CVM_PLUGIN_VERSION="0.0.1"
_CVP_INIT_MARKER="${CVM_DIR:-$HOME/.cvm}/init-ran"
cvm_plugin_main() { echo "main"; }
cvm_plugin_init() { echo "init-ran" > "$_CVP_INIT_MARKER"; }
EOF
  git -C "$repo" init -q
  git -C "$repo" add plugin.sh
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm x

  run bash "$CVM_SCRIPT" plugin install "$repo"
  assert_success
  [ -f "$CVM_DIR/init-ran" ]
}

@test "install succeeds for a plugin without cvm_plugin_init" {
  local repo; repo="$(make_fixture_plugin noinitplg noinitcmd)"
  run bash "$CVM_SCRIPT" plugin install "$repo"
  assert_success
  assert_contains "Installed plugin"
}
