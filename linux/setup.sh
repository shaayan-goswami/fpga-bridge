#!/usr/bin/env bash
#
# One-time setup for the Linux machine that runs Vivado for fpga-bridge.
#
#   1. Checks that an SSH server is running (and installs one with --install-ssh).
#   2. Optionally authorizes your Mac's public key.
#   3. Looks for Tailscale.
#   4. Finds the newest Vivado install and checks that it starts.
#   Then prints the `fpga-bridge init` command to run on your Mac.
#
# Run it as your normal user, not root. Only --install-ssh uses sudo.
#
# Usage:
#   ./setup.sh [--public-key "<contents of ~/.ssh/id_ed25519.pub on your Mac>"] [--install-ssh]
#
# Test hooks (not for normal use): FPGA_BRIDGE_VIVADO_ROOTS is a colon-separated list that replaces the default
# places searched for Vivado.

set -u

ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

# --- SSH server --------------------------------------------------------------

ssh_is_running() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null && return 0
  fi
  pgrep -x sshd >/dev/null 2>&1
}

install_ssh() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y openssh-server && sudo systemctl enable --now ssh
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y openssh-server && sudo systemctl enable --now sshd
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y openssh-server && sudo systemctl enable --now sshd
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm openssh && sudo systemctl enable --now sshd
  else
    return 1
  fi
}

check_ssh() {
  step "SSH server"
  if ssh_is_running; then
    ok "an SSH server is running"
    return 0
  fi
  if [ "${INSTALL_SSH:-0}" = 1 ]; then
    if install_ssh && ssh_is_running; then ok "installed and started the SSH server"; return 0; fi
    warn "couldn't install an SSH server automatically. Install openssh-server with your package manager."
    return 1
  fi
  warn "no SSH server is running. Re-run with --install-ssh, or install openssh-server yourself"
  warn "(Debian/Ubuntu: sudo apt install openssh-server; Fedora: sudo dnf install openssh-server)."
  return 1
}

# --- Authorize the Mac's key -------------------------------------------------

# Appends a public key to ~/.ssh/authorized_keys (once), with the permissions sshd insists on.
authorize_key() {
  local key="$1" dir="$HOME/.ssh" file="$HOME/.ssh/authorized_keys"
  key="$(printf '%s' "$key" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$key" in
    ssh-*|ecdsa-*|sk-*) ;;
    *) return 2 ;;                              # doesn't look like a public key
  esac
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  touch "$file" && chmod 600 "$file" || return 1
  if grep -qxF -- "$key" "$file"; then return 3; fi   # already there
  printf '%s\n' "$key" >> "$file"
}

authorize_step() {
  step "Authorizing your Mac"
  if [ -z "${PUBLIC_KEY:-}" ]; then
    warn 'No --public-key given. Re-run with --public-key "<contents of ~/.ssh/id_ed25519.pub>" (or add the key yourself).'
    return
  fi
  authorize_key "$PUBLIC_KEY"
  case $? in
    0) ok "key added to $HOME/.ssh/authorized_keys" ;;
    3) ok "key already present in $HOME/.ssh/authorized_keys" ;;
    2) warn "that doesn't look like a public key (it should start with ssh-ed25519 or ssh-rsa)" ;;
    *) warn "couldn't write $HOME/.ssh/authorized_keys" ;;
  esac
}

# --- Tailscale ---------------------------------------------------------------

# Prints this machine's Tailscale name, or nothing.
tailscale_name() {
  command -v tailscale >/dev/null 2>&1 || return 1
  local json name
  json="$(tailscale status --self=true --peers=false --json 2>/dev/null)" || return 1
  name="$(printf '%s' "$json" | grep -m1 '"DNSName"' | sed -e 's/.*"DNSName"[^"]*"\([^"]*\)".*/\1/' -e 's/\.$//')"
  [ -n "$name" ] || name="$(tailscale ip -4 2>/dev/null | head -n1)"
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

tailscale_step() {
  step "Tailscale"
  TS_HOST="$(tailscale_name)" || TS_HOST=""
  if [ -n "$TS_HOST" ]; then
    ok "connected as $TS_HOST"
  elif command -v tailscale >/dev/null 2>&1; then
    warn "Tailscale is installed but not connected. Run: sudo tailscale up"
  else
    warn "Tailscale not found. Install it from https://tailscale.com/download to build from outside your network."
  fi
}

# --- Vivado ------------------------------------------------------------------

default_vivado_roots() {
  printf '%s\n' /tools/Xilinx /tools/AMD /opt/Xilinx /opt/AMD /usr/local/Xilinx "$HOME/Xilinx" "$HOME/AMD"
}

# Prints every Vivado launcher found, newest version first. Both install layouts are checked:
#   <root>/Vivado/<version>/bin/vivado   (up to 2024)     <root>/<version>/Vivado/bin/vivado   (2025 on)
find_vivado() {
  local roots root candidate
  if [ -n "${FPGA_BRIDGE_VIVADO_ROOTS:-}" ]; then roots="$(printf '%s' "$FPGA_BRIDGE_VIVADO_ROOTS" | tr ':' '\n')"
  else roots="$(default_vivado_roots)"; fi
  {
    [ -n "${XILINX_VIVADO:-}" ] && [ -x "$XILINX_VIVADO/bin/vivado" ] && echo "$XILINX_VIVADO/bin/vivado"
    command -v vivado 2>/dev/null
    printf '%s\n' "$roots" | while IFS= read -r root; do
      [ -d "$root" ] || continue
      for candidate in "$root"/Vivado/*/bin/vivado "$root"/*/Vivado/bin/vivado; do
        [ -x "$candidate" ] && echo "$candidate"
      done
    done
  } | awk '!seen[$0]++' | while IFS= read -r candidate; do
    # Sort key: the 20xx.y version in the path.
    version="$(printf '%s' "$candidate" | grep -oE '[0-9]{4}\.[0-9]+' | head -n1)"
    printf '%s\t%s\n' "${version:-0.0}" "$candidate"
  done | sort -t "$(printf '\t')" -k1,1Vr | cut -f2-
}

vivado_step() {
  step "Vivado"
  local found
  found="$(find_vivado)"
  if [ -z "$found" ]; then
    warn 'No Vivado install found. Install Vivado, or pass its path to `fpga-bridge init --vivado` yourself.'
    VIVADO=""
    return
  fi
  VIVADO="$(printf '%s\n' "$found" | head -n1)"
  ok "using $VIVADO"
  if [ "$(printf '%s\n' "$found" | wc -l)" -gt 1 ]; then
    echo "  Other installs found:"
    printf '%s\n' "$found" | tail -n +2 | sed 's/^/    /'
  fi
  # fpga-bridge runs Vivado from a login shell, so check that it starts from one (license and environment included).
  local version
  if version="$(bash -lc "'$VIVADO' -version" 2>&1 | grep -m1 -i 'vivado v')"; then
    ok "it starts: $version"
  else
    warn "Vivado is there but didn't start from a login shell. Check its license and that your profile sets up its environment."
  fi
}

# --- Summary -----------------------------------------------------------------

lan_address() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

summary() {
  step "Next: run this on your Mac"
  local host="$TS_HOST"
  if [ -z "$host" ]; then
    host="$(lan_address)"
    [ -n "$host" ] || host="$(hostname)"
    [ -z "$VIVADO" ] || warn "No Tailscale, so using this machine's address on your network ($host). That only works from the same network."
  fi
  if [ -n "$VIVADO" ]; then
    echo
    echo "  fpga-bridge init --host $host --user $USER --vivado \"$VIVADO\" --os linux"
    echo "  fpga-bridge doctor"
    echo
  else
    warn "Fix the warnings above and re-run this script to get the init command."
  fi
}

main() {
  PUBLIC_KEY=""; INSTALL_SSH=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --public-key) PUBLIC_KEY="${2:-}"; shift ;;
      --install-ssh) INSTALL_SSH=1 ;;
      -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
  done
  if [ "$(id -u)" = 0 ]; then
    echo "Run this as your normal user, not root: the key and Vivado have to be set up for the account you will build as." >&2
    exit 1
  fi
  check_ssh || true
  authorize_step
  tailscale_step
  vivado_step
  summary
}

# Run only when executed, so the tests can `source` this file and call the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
