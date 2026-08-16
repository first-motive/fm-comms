#!/usr/bin/env bash
#
# install-client.sh — put the Zenoh CLI tools on a laptop.
#
# A client runs no service and holds no config: it is a developer machine that
# subscribes to the fleet to check what is flowing (`z_sub`, `z_get`). The
# desktop app speaks Zenoh through its own embedded session and needs nothing
# from here.
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

run() {
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would run: $*"
    return 0
  fi
  "$@"
}

do_install() {
  local os version
  os="$(fm_detect_os)"
  version="$(fm_zenoh_version)"
  fm_log "Installing the Zenoh CLI tools (zenoh $version) on $os"

  case "$os" in
    macos)
      fm_require_cmd brew
      run brew tap eclipse-zenoh/homebrew-zenoh
      run brew install zenoh
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

  # The key is the rig's namespace, which is its machine name with underscores:
  # fm-rec-01 publishes under fm_rec_01, and `./run.sh render show` on the rig
  # prints it. A client holds no config of its own, so nothing here is rendered.
  fm_log "  check the fleet with:"
  fm_log "    z_sub -e tcp/<workstation>:7447 -k 'fm_rec_01/joint_states'"
  fm_ok "client install complete."
}

do_uninstall() {
  local os
  os="$(fm_detect_os)"
  fm_log "Removing the Zenoh CLI tools"
  case "$os" in
    macos) run brew uninstall zenoh || true ;;
    linux) run sudo apt-get remove -y zenoh || true ;;
  esac
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
