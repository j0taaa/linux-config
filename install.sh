#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTSTRAP_VERSION="2026-05-04"
readonly NODE_MAJOR="24"
readonly ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.local/share/zsh}"
readonly ZSH_PLUGIN_DIR="$ZSH_CUSTOM_DIR/plugins"
readonly ZSHRC="$HOME/.zshrc"
readonly BASHRC="$HOME/.bashrc"
readonly TMUX_CONF="$HOME/.tmux.conf"
readonly OPENCODE_BIN_DIR="$HOME/.opencode/bin"

DRY_RUN=0

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Linux workstation bootstrap

Usage:
  bash install.sh [--yes] [--dry-run]

Options:
  -y, --yes     Non-interactive mode. Answer yes where package managers ask.
  --dry-run     Print the actions that would run without changing the system.
  -h, --help    Show this help.

Supported distributions:
  Ubuntu/Debian with apt, and CentOS/RHEL/Fedora-family systems with dnf/yum.
EOF
}

while (($#)); do
  case "$1" in
    -y|--yes) ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

run() {
  if ((DRY_RUN)); then
    printf '[dry-run] %q' "$1"
    shift || true
    for arg in "$@"; do printf ' %q' "$arg"; done
    printf '\n'
    return 0
  fi

  "$@"
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

sudo_cmd() {
  if ((EUID == 0)); then
    run "$@"
  else
    need_cmd sudo || die "sudo is required when not running as root"
    run sudo "$@"
  fi
}

curl_to_root_file() {
  local url="$1" path="$2"
  if ((DRY_RUN)); then
    printf '[dry-run] download %s to %s\n' "$url" "$path"
  elif ((EUID == 0)); then
    curl -fsSL "$url" -o "$path"
  else
    curl -fsSL "$url" | sudo tee "$path" >/dev/null
  fi
}

write_root_file() {
  local path="$1" content="$2"
  if ((DRY_RUN)); then
    printf '[dry-run] write %s\n' "$path"
  elif ((EUID == 0)); then
    printf '%s' "$content" > "$path"
  else
    printf '%s' "$content" | sudo tee "$path" >/dev/null
  fi
}

append_root_line() {
  local path="$1" line="$2"
  if ((DRY_RUN)); then
    printf '[dry-run] append %s to %s\n' "$line" "$path"
  elif ((EUID == 0)); then
    printf '%s\n' "$line" >> "$path"
  else
    printf '%s\n' "$line" | sudo tee -a "$path" >/dev/null
  fi
}

detect_os() {
  [[ -r /etc/os-release ]] || die "cannot detect Linux distribution: /etc/os-release is missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"

  if need_cmd apt-get; then
    PKG_MANAGER="apt"
  elif need_cmd dnf; then
    PKG_MANAGER="dnf"
  elif need_cmd yum; then
    PKG_MANAGER="yum"
  else
    die "unsupported package manager; expected apt, dnf, or yum"
  fi
}

pkg_install() {
  case "$PKG_MANAGER" in
    apt)
      sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf)
      sudo_cmd dnf install -y "$@"
      ;;
    yum)
      sudo_cmd yum install -y "$@"
      ;;
  esac
}

pkg_update() {
  case "$PKG_MANAGER" in
    apt) sudo_cmd apt-get update ;;
    dnf) sudo_cmd dnf makecache -y ;;
    yum) sudo_cmd yum makecache -y ;;
  esac
}

install_base_packages() {
  log "Installing base packages"
  case "$PKG_MANAGER" in
    apt)
      sudo_cmd apt-get update
      pkg_install ca-certificates curl wget gnupg lsb-release apt-transport-https software-properties-common git zsh tmux unzip tar gzip build-essential procps
      ;;
    dnf|yum)
      pkg_update
      pkg_install ca-certificates curl wget gnupg2 git zsh tmux unzip tar gzip gcc gcc-c++ make procps-ng shadow-utils
      ;;
  esac
}

install_gh_cli() {
  if need_cmd gh; then
    log "GitHub CLI already installed"
    return
  fi

  log "Installing GitHub CLI"
  case "$PKG_MANAGER" in
    apt)
      sudo_cmd mkdir -p /etc/apt/keyrings
      if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
        if ((DRY_RUN)); then
          printf '[dry-run] install GitHub CLI apt keyring\n'
        else
          curl_to_root_file https://cli.github.com/packages/githubcli-archive-keyring.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg
          sudo_cmd chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        fi
      fi
      if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
        if ((DRY_RUN)); then
          printf '[dry-run] add GitHub CLI apt repository\n'
        else
          write_root_file /etc/apt/sources.list.d/github-cli.list "$(printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$(dpkg --print-architecture)")"
        fi
      fi
      sudo_cmd apt-get update
      pkg_install gh
      ;;
    dnf|yum)
      if need_cmd dnf; then
        sudo_cmd dnf install -y 'dnf-command(config-manager)'
        sudo_cmd dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
      else
        pkg_install yum-utils
        sudo_cmd yum-config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
      fi
      pkg_install gh
      ;;
  esac
}

install_docker() {
  if need_cmd docker && docker compose version >/dev/null 2>&1; then
    log "Docker and Docker Compose already installed"
  else
    log "Installing Docker Engine and Compose plugin"
    case "$PKG_MANAGER" in
      apt)
        sudo_cmd install -m 0755 -d /etc/apt/keyrings
        if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
          if ((DRY_RUN)); then
            printf '[dry-run] install Docker apt key\n'
          else
            curl_to_root_file "https://download.docker.com/linux/${OS_ID}/gpg" /etc/apt/keyrings/docker.asc
            sudo_cmd chmod a+r /etc/apt/keyrings/docker.asc
          fi
        fi
        if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
          if ((DRY_RUN)); then
            printf '[dry-run] add Docker apt repository\n'
          else
            write_root_file /etc/apt/sources.list.d/docker.list "$(printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$OS_ID" "${VERSION_CODENAME:-stable}")"
          fi
        fi
        sudo_cmd apt-get update
        pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
      dnf|yum)
        if need_cmd dnf; then
          sudo_cmd dnf install -y dnf-plugins-core
          sudo_cmd dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        else
          pkg_install yum-utils
          sudo_cmd yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        fi
        pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
    esac
  fi

  if getent group docker >/dev/null 2>&1; then
    if ! id -nG "${SUDO_USER:-$USER}" | tr ' ' '\n' | grep -qx docker; then
      log "Adding ${SUDO_USER:-$USER} to docker group"
      sudo_cmd usermod -aG docker "${SUDO_USER:-$USER}"
      warn "log out and back in for docker group membership to apply"
    fi
  fi

  if need_cmd systemctl; then
    sudo_cmd systemctl enable --now docker || warn "could not enable/start Docker service"
  fi
}

install_node() {
  if need_cmd node && [[ "$(node -v | sed 's/^v//' | cut -d. -f1)" == "$NODE_MAJOR" ]]; then
    log "Node.js $NODE_MAJOR already installed"
    return
  fi

  log "Installing Node.js $NODE_MAJOR"
  case "$PKG_MANAGER" in
    apt)
      if ((DRY_RUN)); then
        printf '[dry-run] run NodeSource apt setup\n'
      else
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
      fi
      pkg_install nodejs
      ;;
    dnf|yum)
      if ((DRY_RUN)); then
        printf '[dry-run] run NodeSource rpm setup\n'
      else
        curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
      fi
      pkg_install nodejs
      ;;
  esac
}

install_bun() {
  if need_cmd bun; then
    log "Bun already installed"
    return
  fi

  log "Installing Bun"
  if ((DRY_RUN)); then
    printf '[dry-run] run Bun installer\n'
  else
    curl -fsSL https://bun.sh/install | bash
  fi
}

install_npm_tools() {
  need_cmd npm || { warn "npm missing; skipping codex and opencode"; return; }

  log "Installing AI developer CLIs"
  local packages=()
  need_cmd codex || packages+=("@openai/codex")

  if ((${#packages[@]})); then
    sudo_cmd npm install -g "${packages[@]}"
  else
    log "Codex already installed"
  fi
}

install_opencode() {
  if [[ -x "$OPENCODE_BIN_DIR/opencode" ]]; then
    log "OpenCode already installed in $OPENCODE_BIN_DIR"
    return
  fi

  log "Installing OpenCode"
  if ((DRY_RUN)); then
    printf '[dry-run] remove old global npm OpenCode package if present\n'
    printf '[dry-run] run OpenCode installer without modifying shell files\n'
  else
    if need_cmd npm && npm list -g opencode-ai --depth=0 >/dev/null 2>&1; then
      sudo_cmd npm uninstall -g opencode-ai || warn "could not remove old global npm OpenCode package"
    fi
    curl -fsSL https://opencode.ai/install | PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" bash -s -- --no-modify-path
  fi
}

sync_git_repo() {
  local repo="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    log "$(basename "$dest") already installed"
  else
    log "Installing $(basename "$dest")"
    run mkdir -p "$(dirname "$dest")"
    run git clone --depth=1 "$repo" "$dest"
  fi
}

install_zsh_plugins() {
  sync_git_repo https://github.com/zsh-users/zsh-autosuggestions "$ZSH_PLUGIN_DIR/zsh-autosuggestions"
  sync_git_repo https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_PLUGIN_DIR/zsh-syntax-highlighting"
}

managed_block() {
  local file="$1" name="$2" content="$3"
  local start="# >>> linux-config:${name} >>>"
  local end="# <<< linux-config:${name} <<<"
  local tmp
  tmp="$(mktemp)"

  run mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || run touch "$file"

  if ((DRY_RUN)); then
    printf '[dry-run] update managed block %s in %s\n' "$name" "$file"
    rm -f "$tmp"
    return
  fi

  awk -v start="$start" -v end="$end" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$file" > "$tmp"

  local rendered
  rendered="$(mktemp)"

  {
    sed -e '${/^$/d;}' "$tmp"
    printf '\n%s\n%s\n%s\n' "$start" "$content" "$end"
  } > "$rendered"

  if cmp -s "$rendered" "$file"; then
    rm -f "$tmp" "$rendered"
    return
  fi

  cp "$rendered" "$file"

  rm -f "$tmp" "$rendered"
}

configure_shell() {
  log "Configuring shell, aliases, completions, and terminal UX"

  local shell_block
  shell_block=$(cat <<'EOF'
export EDITOR="${EDITOR:-nano}"
export VISUAL="$EDITOR"
export BUN_INSTALL="$HOME/.bun"
export PATH="$HOME/.opencode/bin:$BUN_INSTALL/bin:$HOME/.local/bin:$PATH"

autoload -Uz colors 2>/dev/null && colors
PROMPT='%F{cyan}%n@%m%f:%F{yellow}%~%f %# '

alias ll="ls -alF"
alias la="ls -A"
alias l="ls -CF"
alias gs="git status --short --branch"
alias ga="git add"
alias gc="git commit"
alias gp="git push"
alias gl="git log --oneline --decorate --graph --all"
alias d="docker"
alias dc="docker compose"
alias t="tmux new -A -s main"
alias update-system="linux-config-update"
alias fixmouse="printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1015l\e[?1005l'"

linux-config-update() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get autoremove -y
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf upgrade -y
  elif command -v yum >/dev/null 2>&1; then
    sudo yum update -y
  fi
}

if [[ -f "$HOME/.local/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
  source "$HOME/.local/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

if [[ -f "$HOME/.local/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
  source "$HOME/.local/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi

autoload -Uz compinit 2>/dev/null && compinit
zstyle ':completion:*' menu select
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS HIST_IGNORE_DUPS SHARE_HISTORY 2>/dev/null || true
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
EOF
)

  managed_block "$ZSHRC" shell "$shell_block"

  local bash_block
  bash_block=$(cat <<'EOF'
export BUN_INSTALL="$HOME/.bun"
export PATH="$HOME/.opencode/bin:$BUN_INSTALL/bin:$HOME/.local/bin:$PATH"
PS1='\u@\h:\w \$ '
alias ll="ls -alF"
alias gs="git status --short --branch"
alias d="docker"
alias dc="docker compose"
alias t="tmux new -A -s main"
alias fixmouse="printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1015l\e[?1005l'"

EOF
)

  managed_block "$BASHRC" shell "$bash_block"

  local tmux_block
  tmux_block=$(cat <<'EOF'
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g status-interval 5
set -g status-style bg=colour236,fg=colour250
set -g status-left '#[fg=colour82,bold] #S '
set -g status-right '#[fg=colour244]%Y-%m-%d #[fg=colour82]%H:%M '
bind r source-file ~/.tmux.conf \; display-message 'tmux config reloaded'
EOF
)

  managed_block "$TMUX_CONF" tmux "$tmux_block"
}

set_default_shell() {
  local zsh_path
  zsh_path="$(command -v zsh || true)"
  [[ -n "$zsh_path" ]] || { warn "zsh not found; cannot set default shell"; return; }

  if [[ "${SHELL:-}" == "$zsh_path" ]]; then
    log "zsh is already the default shell"
    return
  fi

  local target_user current_shell
  target_user="${SUDO_USER:-$USER}"
  current_shell="$(getent passwd "$target_user" | cut -d: -f7 || true)"
  if [[ "$current_shell" == "$zsh_path" ]]; then
    log "zsh is already the default shell"
    return
  fi

  if ! grep -qxF "$zsh_path" /etc/shells 2>/dev/null; then
    log "Adding zsh to /etc/shells"
    if ((DRY_RUN)); then
      printf '[dry-run] add %s to /etc/shells\n' "$zsh_path"
    else
      append_root_line /etc/shells "$zsh_path"
    fi
  fi

  log "Setting zsh as default shell for $target_user"
  sudo_cmd chsh -s "$zsh_path" "$target_user" || warn "could not change default shell; run: chsh -s $zsh_path"
}

main() {
  [[ "$(uname -s)" == "Linux" ]] || die "this bootstrap is intended for Linux"
  detect_os
  log "linux-config $BOOTSTRAP_VERSION on ${PRETTY_NAME:-$OS_ID}"

  install_base_packages
  install_gh_cli
  install_docker
  install_node
  install_bun
  install_npm_tools
  install_opencode
  install_zsh_plugins
  configure_shell
  set_default_shell

  log "Bootstrap complete. Open a new terminal or run: exec zsh"
}

main "$@"
