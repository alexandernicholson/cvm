# CVM User Guide

CVM (Claude Code Version Manager) lets you install multiple versions of the [Claude Code](https://claude.ai/claude-code) CLI, switch between them globally or per-project, and keep up to date — without touching your system's native Claude installation.

---

## Table of Contents

- [Installation](#installation)
- [Shell Setup](#shell-setup)
- [Quick Start](#quick-start)
- [Installing Versions](#installing-versions)
- [Switching Versions](#switching-versions)
- [Per-project Versions](#per-project-versions)
- [Listing Versions](#listing-versions)
- [Removing Versions](#removing-versions)
- [Updating CVM](#updating-cvm)
- [Plugins & Profiles](#plugins--profiles)
- [Uninstalling CVM](#uninstalling-cvm)
- [Environment Variables](#environment-variables)
- [Troubleshooting](#troubleshooting)

---

## Installation

### macOS / Linux / WSL / Git Bash

```bash
curl -fsSL https://raw.githubusercontent.com/alexandernicholson/cvm/main/install.sh | bash
```

The installer will:
1. Download `cvm` to `~/.cvm/bin/cvm`
2. Detect your shell and offer to add the PATH line to your config file

### Windows (native PowerShell)

```powershell
irm https://raw.githubusercontent.com/alexandernicholson/cvm/main/install.ps1 | iex
```

This installs `cvm.ps1` and a `cvm.cmd` wrapper to `%USERPROFILE%\.cvm\bin\` and adds that directory to your user PATH.

> **WSL users**: Use the bash install above. WSL is a real Linux environment — `linux-x64` binaries work correctly.

> **Git Bash / MSYS2 users**: Use the bash install. CVM detects your MINGW/MSYS environment and selects the `win32-x64` platform automatically.

### Manual installation (bash)

```bash
mkdir -p ~/.cvm/bin
curl -fsSL https://raw.githubusercontent.com/alexandernicholson/cvm/main/cvm.sh \
  -o ~/.cvm/bin/cvm
chmod +x ~/.cvm/bin/cvm
```

---

## Shell Setup

Add the appropriate line to your shell config, then reload your shell.

**bash** — `~/.bashrc`:
```bash
export PATH="$HOME/.cvm/bin:$PATH"
```

**zsh** — `~/.zshrc`:
```bash
export PATH="$HOME/.cvm/bin:$PATH"
```

**fish** — `~/.config/fish/config.fish`:
```fish
fish_add_path $HOME/.cvm/bin
```

**PowerShell** — `$PROFILE`:
```powershell
$env:PATH = "$env:USERPROFILE\.cvm\bin;$env:PATH"
```

Not sure which to use? Run `cvm env` and it will print the right line for your current shell.

```bash
cvm env           # auto-detects your shell
cvm env --bash    # force bash syntax
cvm env --zsh     # force zsh syntax
cvm env --fish    # force fish syntax
cvm env --pwsh    # force PowerShell syntax
```

---

## Quick Start

```bash
# Install the latest version
cvm install latest

# Check it works
claude --version

# See all installed versions
cvm ls

# Browse available versions
cvm ls-remote
```

---

## Installing Versions

```bash
cvm install latest        # latest available
cvm install stable        # latest stable release
cvm install 2.1.71        # exact version
cvm install v2.1.71       # leading 'v' is stripped automatically
```

**Channels:**

| Channel | Description |
|---|---|
| `latest` | Most recent release |
| `stable` | Last designated stable release |

CVM downloads the pre-compiled native binary for your platform directly from Anthropic's distribution servers, verifies the SHA256 checksum against the release manifest, and installs it to `~/.cvm/versions/<version>/claude`.

---

## Switching Versions

### Global (system-wide)

Sets the active version for all shells and sessions:

```bash
cvm use 2.1.71
cvm use latest      # resolves channel first
```

This updates the symlink at `~/.cvm/bin/claude` and writes the version to `~/.cvm/version`.

### Checking the active version

```bash
cvm current         # prints active version (or "none")
cvm which           # prints full path to active claude binary
```

---

## Per-project Versions

Pin a specific version to a directory by creating a `.claude-version` file:

```bash
cd my-project
cvm local 2.1.58
```

This writes `2.1.58` to `.claude-version` in the current directory. You can commit this file to keep your whole team on the same version.

When you run `claude` inside `my-project` (or any subdirectory), CVM resolves the version from `.claude-version` rather than the global default.

### Version resolution order

```
$CVM_VERSION env var        (highest priority)
    ↓
.claude-version file        (walks up from $PWD to /)
    ↓
~/.cvm/version              (global default, set by cvm use)
    ↓
error: no version active
```

### Override for a single command

```bash
CVM_VERSION=2.1.55 claude --version
```

---

## Listing Versions

### Installed versions

```bash
cvm ls
```

```
Installed versions:
  → 2.1.71  (active)
    2.1.58
    2.1.55
```

### Available versions

```bash
cvm ls-remote            # last 20 available versions
cvm ls-remote --all      # every available version
```

Version data is fetched from two independent sources (GitHub tags and the npm registry) and merged, so the list remains available even if one source is down.

---

## Removing Versions

```bash
cvm uninstall 2.1.55
```

If the version being removed is currently active, CVM clears the global default and symlink, and reminds you to set a new active version with `cvm use`.

---

## Updating CVM

Update CVM itself to the latest version:

```bash
cvm self-update
```

---

## Plugins & Profiles

### Plugins

CVM can install plugins — git repos that add new `cvm <command> ...` subcommands.

```bash
cvm plugin install alexandernicholson/cvp   # the profile manager
cvm plugin list
cvm plugin update cvp
cvm plugin uninstall cvp
```

A plugin is a git repo with a `plugin.sh` that declares `CVM_PLUGIN_COMMAND`
and a `cvm_plugin_main()` handler. When you run `cvm <command> ...` and
`<command>` isn't a core CVM command, CVM looks for a plugin that registered it
and delegates.

### Env hooks

The active `claude` on your PATH is a bash wrapper (macOS/Linux). Before
exec'ing the real versioned binary it sources every `~/.cvm/env.d/*.sh`, so
plugins can inject environment variables into every `claude` invocation.
(The Windows native / PowerShell path keeps the legacy symlink model.)

### Profiles (via the [cvp](https://github.com/alexandernicholson/cvp) plugin)

`cvp` lets you define named profiles of environment variables — e.g. a custom
inference gateway with `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_OAUTH_TOKEN`, and
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` — and switch them per-directory **or**
globally, **without losing any saved keys or URLs**.

The global "active profile" is just an **alias** (a name in `~/.cvm/active-profile`)
pointing at a profile definition stored in `~/.cvm/profiles/<name>.env`.
Switching profiles only rewrites the alias; the profile settings are never
touched, so you can switch back and forth freely.

```bash
cvm plugin install alexandernicholson/cvp
cvm profile add work            # create/edit a profile (prompts for vars)
cvm profile use work            # set the global alias
cvm profile local work          # pin this directory to a profile
cvm profile current             # show the resolved profile
cvm profile ls
cvm profile show                # display the active profile (secrets masked)
cvm profile env                 # print `export` lines (for `eval`)
```

Profile resolution order (applied per `claude` invocation by the env hook):

```
$CVM_PROFILE env var          (highest priority)
    ↓
.claude-profile file          (walks up from $PWD to /)
    ↓
~/.cvm/active-profile         (global alias, set by cvm profile use)
    ↓
(none — no profile applied)
```

Because resolution happens at runtime inside the wrapper, a per-directory
`.claude-profile` takes effect for `claude` in that tree without any shell
reload.

---

## Uninstalling CVM

Remove CVM and all installed Claude Code versions:

```bash
cvm self-uninstall
```

Then remove the PATH line from your shell config file.

---

## Environment Variables

| Variable | Description |
|---|---|
| `CVM_VERSION` | Override the active version for the current session/command |
| `CVM_DIR` | Override the CVM home directory (default: `~/.cvm`) |

---

## Troubleshooting

### `claude: command not found`

`~/.cvm/bin` is not on your PATH. Run `cvm env` for the correct line to add to your shell config, add it, then reload your shell.

### `No version active`

No version has been set. Run `cvm install latest && cvm use latest`.

### `cvm use` says version not installed

The version exists in the remote registry but hasn't been downloaded yet. Run `cvm install <version>` first.

### Checksum verification failed

The downloaded binary didn't match Anthropic's published SHA256. This can happen with a partial download. Delete the file from `~/.cvm/cache/` and retry.

### `ls-remote` fails

Both GitHub tags API and the npm registry were unreachable. Check your network connection and try again.

### Wrong `claude` is running

If `which claude` doesn't show a path inside `~/.cvm/bin/`, another installation is taking precedence. Make sure `export PATH="$HOME/.cvm/bin:$PATH"` appears **before** any other PATH additions in your shell config, and reload your shell.
