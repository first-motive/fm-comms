#!/usr/bin/env bash
#
# install-router.sh — stand this host up as THE First Motive Zenoh router.
#
# One router serves the whole fleet, on the office workstation. Every bridge and
# every client connects to it in client mode. Running a second router partitions
# the fleet, so this script is meant to run on exactly one machine.
#
# Runnable standalone or through the front door:
#     ./scripts/install-router.sh [install|uninstall]
#     ./install.sh --role router
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

# lib.sh owns the path so the installers, the render verb, and the episodes verb
# cannot disagree about which file the fleet-wide values live in.
ENV_FILE="$FM_COMMS_ENV_FILE"
CONF_DIR=/etc/fm-comms
UNIT=fm-zenohd.service

run() {
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would run: $*"
    return 0
  fi
  "$@"
}

install_linux() {
  local version="$1"
  # Adds the Eclipse repo with its signing key checked against the pinned
  # fingerprint; see fm_apt_add_zenoh_repo in lib.sh.
  fm_apt_add_zenoh_repo run
  # Pinned exactly: an unpinned upgrade would drift this router away from the
  # bridges and silently break the fleet on a routine apt upgrade.
  run sudo apt-get install -y "zenoh=$version"
}

install_macos() {
  local version="$1"
  fm_require_cmd brew
  run brew tap eclipse-zenoh/homebrew-zenoh
  run brew install zenoh
  # Homebrew installs the tap's current formula; it has no per-version pin, so
  # verify rather than assume, and say so plainly when it drifts.
  if [ "$FM_DRY_RUN" != "1" ]; then
    local got
    got="$(zenohd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [ -n "$got" ] && [ "$got" != "$version" ]; then
      fm_warn "  brew installed zenohd $got, but the fleet is pinned to $version"
      fm_warn "  the router and the rigs must match — pin the tap or update zenoh/zenoh.version"
    fi
  fi
}

place_env() {
  if [ -f "$ENV_FILE" ]; then
    fm_log "  $ENV_FILE exists; leaving it alone"
    return 0
  fi
  fm_log "  placing $ENV_FILE from the example"
  run sudo install -m 0644 "$ROOT/systemd/fm-comms.env.example" "$ENV_FILE"
  fm_warn "  fill in $ENV_FILE, then re-run this script"
  return 1
}

do_install() {
  local os version
  os="$(fm_detect_os)"
  version="$(fm_zenoh_version)"

  # The card decides whether this host belongs on the Zenoh fabric at all. A
  # machine still on dds-lan gets a clear refusal here rather than a second,
  # contradictory transport running beside the one it already speaks.
  fm_comms_require_transport || return 1

  fm_log "Installing the Zenoh router (zenoh $version) on $os"

  case "$os" in
    linux) install_linux "$version" ;;
    macos) install_macos "$version" ;;
  esac

  place_env || return 0

  fm_log "  rendering $CONF_DIR/router.json5"
  run sudo mkdir -p "$CONF_DIR"
  if [ "$FM_DRY_RUN" = "1" ]; then
    # Print the config rather than describing it: a dry run whose only output is
    # "would render X" cannot catch the mistake the render itself would make.
    fm_log "  would write $CONF_DIR/router.json5:"
    fm_comms_render router -
  else
    local tmp; tmp="$(mktemp)"
    fm_comms_render router "$tmp"
    sudo install -m 0644 "$tmp" "$CONF_DIR/router.json5"
    rm -f "$tmp"
  fi

  if [ "$os" = linux ]; then
    fm_log "  installing $UNIT"
    run sudo install -m 0644 "$ROOT/systemd/$UNIT" "/etc/systemd/system/$UNIT"
    run sudo systemctl daemon-reload
    run sudo systemctl enable --now "$UNIT"
    fm_log "  watch it with: journalctl -u $UNIT -f"
  else
    fm_log "  macOS has no unit; run it in the foreground with:"
    fm_log "    zenohd --config $CONF_DIR/router.json5"
  fi

  fm_ok "router install complete."
}

do_uninstall() {
  local os
  os="$(fm_detect_os)"
  fm_log "Removing the Zenoh router"
  if [ "$os" = linux ]; then
    run sudo systemctl disable --now "$UNIT" || true
    run sudo rm -f "/etc/systemd/system/$UNIT"
    run sudo systemctl daemon-reload
  fi
  # Only what this script placed. $ENV_FILE holds the operator's own values and
  # the zenoh package may serve other things on this host, so neither is touched.
  run sudo rm -f "$CONF_DIR/router.json5"
  fm_log "  left in place: $ENV_FILE and the zenoh package"
  fm_ok "router uninstall complete."
}

main() {
  case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *) fm_err "usage: $0 [install|uninstall]"; return 1 ;;
  esac
}

main "$@"
