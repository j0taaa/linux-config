# linux-config

Idempotent Linux workstation bootstrap for Ubuntu/Debian and CentOS/RHEL/Fedora-family systems.

It installs and configures:

- `zsh` as the default shell, with autocomplete, autosuggestions, syntax highlighting, and a simple inline prompt
- `tmux`, Git, GitHub CLI, Docker Engine, Docker Compose plugin
- Node.js 24, Bun, Codex CLI, OpenCode CLI installed under `~/.opencode/bin`
- Useful aliases, including:

```sh
alias fixmouse="printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1015l\e[?1005l'"
```

The script is safe to run more than once. Existing tools and plugin repositories are skipped, missing packages are installed, and shell/tmux config is written inside managed blocks that are replaced only when their contents change.

If you previously ran an older version that enabled the default Starship prompt, rerun this script to replace the managed block with the simpler inline prompt.

## Run directly from this repository

```sh
curl -fsSL https://raw.githubusercontent.com/j0taaa/linux-config/main/install.sh | bash -s -- --yes
```

## Run from a GitHub Gist

Use the raw gist URL:

```sh
curl -fsSL https://gist.githubusercontent.com/j0taaa/4a7b1373f5ecd3f3ee1e3ffc68e0c4e1/raw/install.sh | bash -s -- --yes
```

## Local usage

```sh
bash install.sh --yes
```

Preview without changing the machine:

```sh
bash install.sh --dry-run
```

## Notes

- Docker group membership requires logging out and back in before running Docker without `sudo`.
- Changing the default shell may require the user password on some distributions.
- `gh auth login` is intentionally not automated because it requires your GitHub authentication.
