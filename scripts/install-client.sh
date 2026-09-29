#!/usr/bin/env bash
#
# install-client.sh — put the Zenoh CLI tools on a laptop.
#
# A client runs no service: it is a developer machine that subscribes to the
# fleet to check what is flowing (`z_sub`, `z_get`) and drives robots with
# `fm robot`. The one config it holds is where the router is — FM_ROUTER_ENDPOINT
# in the fleet env file, which `fm robot` reads. The desktop app speaks Zenoh
# through its own embedded session and needs nothing from here.
#
# Runnable standalone or through the front door:
#     ./scripts/install-client.sh [install|uninstall]
#     ./install.sh --role client
#
# Env (install.sh passes these down; both default to off):
#   FM_DRY_RUN=1   print what would happen, change nothing
#   FM_YES=1       assume yes, prompt for nothing

set -euo pipefail

FM_DRY_RUN="${FM_DRY_RUN:-0}"
FM_YES="${FM_YES:-0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh disable=SC1091
. "$ROOT/lib.sh"

ENV_FILE="$FM_COMMS_ENV_FILE"

run() {
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would run: $*"
    return 0
  fi
  "$@"
}

# Place the fleet env file so `fm robot` finds the router. Without it the CLI on
# a Mac needed FM_ROUTER_ENDPOINT exported for every command (2026-09-29). A
# missing endpoint is a warning, not a failure: the tools themselves installed.
place_env() {
  if [ -f "$ENV_FILE" ]; then
    fm_log "  $ENV_FILE exists; leaving it alone"
  else
    fm_log "  placing $ENV_FILE from the example"
    run sudo install -m 0644 "$ROOT/systemd/fm-comms.env.example" "$ENV_FILE"
  fi
  [ "$FM_DRY_RUN" = "1" ] && return 0
  fm_comms_env_seed FM_ROUTER_ENDPOINT "${FM_ROUTER_ENDPOINT:-}"
  local missing
  missing="$(fm_comms_env_unfilled FM_ROUTER_ENDPOINT)"
  [ -z "$missing" ] && return 0
  fm_warn "  fill in $ENV_FILE ($missing) so fm robot and z_sub find the router"
  fm_warn "  on a Mac use the router's tailnet address, e.g. tcp/<router>.<tailnet>.ts.net:7447"
}

do_install() {
  local os version
  os="$(fm_detect_os)"
  version="$(fm_zenoh_version)"
  fm_log "Installing the Zenoh CLI tools (zenoh $version) on $os"

  case "$os" in
    macos)
      # Pinned standalone build, not the brew tap — see fm_install_zenohd_macos.
      fm_install_zenohd_macos "$version"
      # Outside pixi on purpose: there is no conda-forge zenoh package, and the
      # ROS env has no business carrying the transport's CLI.
      fm_log "  installed outside the pixi env — these are host tools, not ROS deps"
      ;;
    linux)
      # Adds the Eclipse repo with its signing key checked against the pinned
      # fingerprint; see fm_apt_add_zenoh_repo in lib.sh.
      fm_apt_add_zenoh_repo run
      run sudo apt-get install -y "zenoh=$version"
      ;;
  esac

  place_env

  # The key is the rig's namespace, which is its machine name with underscores:
  # fm-rec-01 publishes under fm_rec_01, and `./run.sh render show` on the rig
  # prints it. A client runs no bridge, so nothing here is rendered.
  fm_log "  check the fleet with:"
  fm_log "    z_sub -e \"\$FM_ROUTER_ENDPOINT\" -k 'fm_rec_01/joint_states'"
  fm_log "    fm robot list"
  fm_ok "client install complete."
}

do_uninstall() {
  local os
  os="$(fm_detect_os)"
  fm_log "Removing the Zenoh CLI tools"
  case "$os" in
    macos) run rm -f "$HOME/.local/bin/zenohd" ;;
    linux) run sudo apt-get remove -y zenoh || true ;;
  esac
  # The env file holds the operator's own values, so it outlives the tools.
  fm_log "  left in place: $ENV_FILE"
  fm_ok "client uninstall complete."
}

main() {
  case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *) fm_err "usage: $0 [install|uninstall]"; return 1 ;;
  esac
}

main "$@"
