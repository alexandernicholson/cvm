# CVM — Claude Code Version Manager

Install, manage, and switch between versions of the [Claude Code](https://claude.ai/claude-code) CLI. Inspired by `rbenv`, `tfenv`, and `rustup`.

```
cvm install latest        # install the latest version
cvm use 2.1.58            # switch globally
cvm local 2.1.71          # pin a project directory
```

---

## Table of Contents

- [Installation](#installation)
- [Shell Setup](#shell-setup)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Version Resolution](#version-resolution)
- [Architecture](#architecture)
- [Supported Platforms](#supported-platforms)
- [Requirements](#requirements)
- [Documentation](#documentation)
- [Development](#development)

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/alexandernicholson/cvm/main/install.sh | bash
```

The installer downloads CVM to `~/.cvm/bin/cvm`, detects your shell, and offers to add the PATH line to your config automatically.

### Manual installation

```bash
mkdir -p ~/.cvm/bin
curl -fsSL https://raw.githubusercontent.com/alexandernicholson/cvm/main/cvm.sh \
  -o ~/.cvm/bin/cvm
chmod +x ~/.cvm/bin/cvm
```

---

## Shell Setup

Add `~/.cvm/bin` to your PATH. Run `cvm env` to print the correct line for your shell:

```bash
cvm env           # auto-detects your shell
cvm env --bash    # force bash syntax
cvm env --zsh     # force zsh syntax
cvm env --fish    # force fish syntax
```

| Shell | Config file | Line to add |
|---|---|---|
| bash | `~/.bashrc` | `export PATH="$HOME/.cvm/bin:$PATH"` |
| zsh | `~/.zshrc` | `export PATH="$HOME/.cvm/bin:$PATH"` |
| fish | `~/.config/fish/config.fish` | `fish_add_path $HOME/.cvm/bin` |

After adding the line, reload your shell (`source ~/.zshrc` or open a new terminal).

---

## Quick Start

```bash
# Install the latest version
cvm install latest

# Verify it works
claude --version

# See installed versions
cvm ls

# Browse all available versions
cvm ls-remote --all
```

---

## Commands

| Command | Description |
|---|---|
| `cvm install <version>` | Install a version (`latest`, `stable`, or semver e.g. `2.1.71`) |
| `cvm use <version>` | Set the global active version |
| `cvm local <version>` | Pin the current directory (writes `.claude-version`) |
| `cvm current` | Show the currently resolved version |
| `cvm which` | Print the full path to the active `claude` binary |
| `cvm ls` | List installed versions |
| `cvm ls-remote [--all]` | List versions available for download |
| `cvm uninstall <version>` | Remove an installed version |
| `cvm env [--bash\|--zsh\|--fish]` | Print the PATH setup line for your shell |
| `cvm self-update` | Update CVM itself to the latest version |
| `cvm self-uninstall` | Remove CVM and all installed Claude Code versions |

### Install channels

```bash
cvm install latest     # most recent release
cvm install stable     # last designated stable release
cvm install 2.1.71     # exact version
cvm install v2.1.71    # leading 'v' is stripped automatically
```

### Per-project versions

```bash
cd my-project
cvm local 2.1.58       # writes .claude-version in this directory
```

Commit `.claude-version` to keep your whole team on the same version. Override for a single command:

```bash
CVM_VERSION=2.1.55 claude --version
```

---

## Version Resolution

CVM resolves the active version in this order:

```
$CVM_VERSION env var        (highest priority)
    ↓
.claude-version file        (walks up from $PWD to /)
    ↓
~/.cvm/version              (global default, set by cvm use)
    ↓
error: no version active
```

```mermaid
flowchart TD
    A[cvm_resolve_version] --> B{$CVM_VERSION set?}
    B -- yes --> Z[return $CVM_VERSION]
    B -- no --> C[dir = $PWD]
    C --> D{.claude-version<br>exists in dir?}
    D -- yes --> Z2[return contents]
    D -- no --> E{dir == /}
    E -- yes --> F{~/.cvm/version<br>exists?}
    E -- no --> G[dir = parent of dir]
    G --> D
    F -- yes --> Z3[return contents]
    F -- no --> ERR[return error]
```

---

## Architecture

CVM is a single bash script with no runtime dependencies beyond `bash`, `curl`, and either `python3` or `jq`. It uses the symlink-switching model from `tfenv` and `rbenv`.

```mermaid
graph TD
    U["User runs: cvm <command>"]
    U --> D{Dispatch}

    D --> I[cmd_install]
    D --> US[cmd_use]
    D --> L[cmd_local]
    D --> CU[cmd_current]
    D --> LS[cmd_list]
    D --> LR[cmd_list_remote]
    D --> UN[cmd_uninstall]

    I --> PD[detect_platform]
    I --> DL["Download binary<br>GCS bucket"]
    I --> CV[verify_checksum<br>SHA256 from manifest]
    I --> SYM[update_symlink]

    LR --> GH["GitHub tags API"]
    LR --> NP["npm registry"]
    LR --> MR[Merge + deduplicate<br>sort_versions]
```

### Directory layout

```
~/.cvm/
├── bin/
│   ├── cvm             ← CVM script itself
│   └── claude          → symlink to active version binary
├── versions/
│   ├── 2.1.58/
│   │   └── claude      ← downloaded native binary
│   └── 2.1.71/
│       └── claude
├── version             ← global default (plain text, e.g. "2.1.71")
└── cache/              ← temporary download staging (cleaned after install)
```

Only `~/.cvm/bin` needs to be on `$PATH`.

### Version listing: dual-source strategy

`cvm ls-remote` fetches from **GitHub tags** and the **npm registry** independently, then merges and deduplicates the results. If one source is rate-limited or down, the other covers it. Only if both are unreachable does the command fail.

### Binary distribution

Claude Code native binaries are served by Anthropic from a GCS bucket. CVM downloads the binary for your platform, verifies its SHA256 checksum against the release manifest, then moves it to `~/.cvm/versions/<version>/claude`. A failed checksum leaves no partial install.

---

## Supported Platforms

| Platform | OS | Architecture |
|---|---|---|
| `darwin-arm64` | macOS | Apple Silicon (M-series) |
| `darwin-x64` | macOS | Intel |
| `linux-arm64` | Linux (glibc) | ARM64 |
| `linux-x64` | Linux (glibc) | x86_64 |
| `linux-arm64-musl` | Linux (musl/Alpine) | ARM64 |
| `linux-x64-musl` | Linux (musl/Alpine) | x86_64 |

CVM auto-detects your platform, including Rosetta 2 on Apple Silicon Macs and musl on Alpine Linux.

---

## Requirements

- **bash** 4.0 or later (macOS ships bash 3.2; install a newer version via Homebrew: `brew install bash`)
- **curl**
- **python3** or **jq** (for JSON parsing in `ls-remote` and checksum extraction; `python3` is usually pre-installed)

---

## Documentation

Full documentation lives in [`docs/`](docs/):

- **[User Guide](docs/user-guide.md)** — installation, shell setup, all commands, per-project versions, troubleshooting
- **[Technical Reference](docs/technical.md)** — architecture, distribution infrastructure, version resolution algorithm, platform detection, testing

---

## Development

```bash
make test           # run all 173 tests
make test-verbose   # TAP output
make lint           # bash -n syntax check
make install-bats   # install bats-core (via Homebrew or npm)
```

Tests use [bats-core](https://github.com/bats-core/bats-core) with a mock `curl` that intercepts all HTTP calls. Each test runs in an isolated `$CVM_DIR` and never touches `~/.cvm` or the real filesystem.

### Test suite overview

| File | Tests | Coverage |
|---|---|---|
| `00-help.bats` | 12 | help, version, unknown commands |
| `01-version-resolution.bats` | 11 | env var, walk-up, global default |
| `02-install.bats` | 16 | install, channels, checksums |
| `03-use.bats` | 10 | global switching, symlinks |
| `04-local.bats` | 9 | per-directory `.claude-version` |
| `05-current-which.bats` | 15 | current/which resolution |
| `06-list.bats` | 22 | ls, ls-remote, dual-source resilience |
| `07-uninstall.bats` | 13 | removal, active version handling |
| `08-edge-cases.bats` | 14 | self-update, self-uninstall, idempotency |
| `09-shells.bats` | 51 | bash/zsh/fish compatibility |

### Contributing

1. Fork and clone the repo
2. Make changes to `cvm.sh` or `install.sh`
3. Run `make test` — all 173 tests must pass
4. Open a pull request

---

## Uninstalling CVM

```bash
cvm self-uninstall
# then remove the PATH line from your shell config file
```
