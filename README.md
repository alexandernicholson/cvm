# CVM — Claude (Code) Version Manager

Install, manage, and switch between versions of the [Claude Code](https://claude.ai/claude-code) CLI.

```
cvm install latest        # install latest version
cvm use 2.1.58            # switch globally
cvm local 2.1.71          # pin a project directory
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/alexandernicholson/cvm/main/install.sh | bash
```

Then add to your shell rc file (`~/.zshrc`, `~/.bashrc`):

```bash
export PATH="$HOME/.cvm/bin:$PATH"
```

Reload your shell, then install Claude Code:

```bash
cvm install latest
claude --version
```

## Commands

| Command | Description |
|---|---|
| `cvm install <version>` | Install a version (`latest`, `stable`, or semver e.g. `2.1.71`) |
| `cvm use <version>` | Set the global active version |
| `cvm local <version>` | Pin current directory (writes `.claude-version`) |
| `cvm current` | Show currently resolved version |
| `cvm which` | Print path to active `claude` binary |
| `cvm ls` | List installed versions |
| `cvm ls-remote [--all]` | List versions available for download |
| `cvm uninstall <version>` | Remove an installed version |
| `cvm self-update` | Update CVM itself |
| `cvm self-uninstall` | Remove CVM and all installed versions |

## Version Resolution

CVM resolves the active version in this order:

1. `$CVM_VERSION` environment variable
2. `.claude-version` file (walks up directory tree to `$HOME`)
3. `~/.cvm/version` — global default (set by `cvm use`)

This mirrors the behaviour of `rbenv`/`pyenv`: projects can pin their own version, individual shell sessions can override with `CVM_VERSION`, and the global default is always a fallback.

## Local (per-project) Versions

```bash
cd my-project
cvm local 2.1.58         # writes .claude-version
echo ".claude-version" >> .gitignore   # or commit it for team consistency
```

When you `cd` into `my-project`, `claude` automatically resolves to `2.1.58`.

## Directory Layout

```
~/.cvm/
  bin/
    cvm               <- CVM itself
    claude            -> symlink to active version
  versions/
    2.1.58/
      claude          <- binary
    2.1.71/
      claude
  version             <- global default (plain text)
  cache/              <- temporary downloads (cleaned after install)
```

## Requirements

- bash 4+ (macOS ships bash 3; install via Homebrew: `brew install bash`)
- curl
- python3 or jq (for `ls-remote` and checksum verification; python3 is usually pre-installed)

## Platforms

| Platform | Supported |
|---|---|
| macOS ARM64 (M-series) | yes |
| macOS x86_64 | yes |
| Linux x86_64 (glibc) | yes |
| Linux ARM64 (glibc) | yes |
| Linux x86_64 (musl/Alpine) | yes |
| Linux ARM64 (musl/Alpine) | yes |
| Windows | no |

## Uninstall

```bash
cvm self-uninstall
# then remove the PATH line from your shell rc file
```
