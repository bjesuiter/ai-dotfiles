#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ai-dotfiles"
STATE_FILE="$STATE_DIR/init-vserv.state"
LOG_FILE="$STATE_DIR/init-vserv.log"
CURRENT_STEP=""

mkdir -p "$STATE_DIR"
touch "$STATE_FILE" "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

step_done() {
  grep -Fxq "$1" "$STATE_FILE" 2>/dev/null
}

mark_step_done() {
  printf '%s\n' "$1" >> "$STATE_FILE"
}

run_step() {
  local step="$1"
  shift

  if step_done "$step"; then
    log "Skipping $step (already completed)"
    return 0
  fi

  CURRENT_STEP="$step"
  log "Starting $step"
  "$@"
  mark_step_done "$step"
  log "Finished $step"
  CURRENT_STEP=""
}

trap 'rc=$?; log "Step ${CURRENT_STEP:-unknown} failed with exit code $rc. Re-run this script to resume from the last unfinished step."; log "State file: $STATE_FILE"; exit $rc' ERR

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Missing required command: $1"
    exit 1
  }
}

run_as_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

append_block_if_missing() {
  local file="$1"
  local marker="$2"
  local content="$3"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  if grep -Fq "# >>> $marker >>>" "$file"; then
    return 0
  fi

  {
    printf '\n# >>> %s >>>\n' "$marker"
    printf '%s\n' "$content"
    printf '# <<< %s <<<\n' "$marker"
  } >> "$file"
}

refresh_bun_env() {
  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  mkdir -p "$BUN_INSTALL"

  case ":$PATH:" in
    *":$BUN_INSTALL/bin:"*) ;;
    *) export PATH="$BUN_INSTALL/bin:$PATH" ;;
  esac
}

refresh_fnm_env() {
  local fnm_root="$HOME/.local/share/fnm"

  case ":$PATH:" in
    *":$fnm_root:"*) ;;
    *) export PATH="$fnm_root:$PATH" ;;
  esac

  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash)"
  fi
}

locale_available() {
  local wanted
  wanted="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' | grep -Fxq "$wanted"
}

generate_locale() {
  local locale_name="$1"
  local locale_pattern="${locale_name//./\\.}"

  if locale_available "$locale_name"; then
    log "Locale $locale_name already available"
    return 0
  fi

  if [ -f /etc/locale.gen ]; then
    if grep -Eq "^[#[:space:]]*${locale_pattern}[[:space:]]+UTF-8" /etc/locale.gen; then
      run_as_root sed -i -E "s/^#?[[:space:]]*(${locale_pattern}[[:space:]]+UTF-8)/\\1/" /etc/locale.gen
    else
      printf '%s UTF-8\n' "$locale_name" | run_as_root tee -a /etc/locale.gen >/dev/null
    fi
  fi

  run_as_root locale-gen "$locale_name"

  if ! locale_available "$locale_name"; then
    log "Failed to generate locale $locale_name"
    return 1
  fi

  log "Generated locale $locale_name"
}

configure_locales() {
  local desired_locale="${INIT_VSERV_LOCALE:-de_DE.UTF-8}"
  local fallback_locale="en_US.UTF-8"

  generate_locale "$desired_locale"

  if [ "$desired_locale" != "$fallback_locale" ]; then
    generate_locale "$fallback_locale"
  fi
}

install_apt_packages() {
  run_as_root apt-get update -y
  run_as_root apt-get install -y fish curl ca-certificates unzip xz-utils locales
}

install_starship() {
  if command -v starship >/dev/null 2>&1; then
    log "starship already installed"
    return 0
  fi

  curl -sS https://starship.rs/install.sh | sh -s -- -y
}

configure_starship() {
  append_block_if_missing "$HOME/.config/starship.toml" "ai-dotfiles starship container" '[container]
disabled = true'
}

install_bun() {
  if command -v bun >/dev/null 2>&1; then
    log "bun already installed"
    refresh_bun_env
    return 0
  fi

  curl -fsSL https://bun.com/install | bash
  refresh_bun_env
}

install_fnm() {
  if command -v fnm >/dev/null 2>&1; then
    log "fnm already installed"
    refresh_fnm_env
    return 0
  fi

  curl -fsSL https://fnm.vercel.app/install | bash
  refresh_fnm_env
}

install_node_lts() {
  refresh_fnm_env
  fnm install --lts
  fnm default "$(fnm current)"
}

install_pi() {
  refresh_bun_env

  if command -v pi >/dev/null 2>&1; then
    log "pi already installed"
    return 0
  fi

  bun install -g @mariozechner/pi-coding-agent
}

configure_bash() {
  append_block_if_missing "$HOME/.bashrc" "ai-dotfiles managed env" 'export BUN_INSTALL="$HOME/.bun"
[ -d "$BUN_INSTALL/bin" ] && export PATH="$BUN_INSTALL/bin:$PATH"
[ -d "$HOME/.local/share/fnm" ] && export PATH="$HOME/.local/share/fnm:$PATH"
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd --shell bash)"
fi
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init bash)"
fi'

  append_block_if_missing "$HOME/.profile" "ai-dotfiles source bashrc" 'if [ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi'
}

configure_fish() {
  mkdir -p "$HOME/.config/fish/conf.d"

  cat > "$HOME/.config/fish/conf.d/ai-dotfiles.fish" <<'EOF'
set -gx BUN_INSTALL "$HOME/.bun"
if test -d "$BUN_INSTALL/bin"
    fish_add_path "$BUN_INSTALL/bin"
end

if test -d "$HOME/.local/share/fnm"
    fish_add_path "$HOME/.local/share/fnm"
end

if type -q fnm
    fnm env --use-on-cd --shell fish | source
end

if type -q starship
    starship init fish | source
end
EOF
}

main() {
  log "State file: $STATE_FILE"
  log "Log file: $LOG_FILE"
  log "Re-run this script anytime to resume safely after a disconnect."

  if ! command -v apt-get >/dev/null 2>&1; then
    log "This script currently supports Debian/Ubuntu systems with apt-get."
    exit 1
  fi

  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    require_cmd sudo
  fi

  export DEBIAN_FRONTEND=noninteractive

  run_step apt_packages install_apt_packages
  run_step locales configure_locales
  run_step starship install_starship
  run_step starship_config configure_starship
  run_step bun install_bun
  run_step fnm install_fnm
  run_step node_lts install_node_lts
  run_step bash_config configure_bash
  run_step fish_config configure_fish
  run_step pi install_pi

  log "All steps completed. Open a new shell, or run: source ~/.bashrc"
}

main "$@"
