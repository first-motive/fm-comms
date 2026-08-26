#!/usr/bin/env bash
#
# install-router.sh — stand this host up as THE First Motive Zenoh router.
#
# One router serves the whole fleet. Every bridge and every client connects to it
# in client mode. Running a second router partitions the fleet, so this script is
# meant to run on exactly one machine.
#
# That machine is the always-on office Mac mini, not the GPU workstation: the
# workstation is wiped, rebooted, and loaded with sim and inference, and every
# reboot would take the fleet's discovery point with it. On macOS the router runs
# under launchd as a LaunchDaemon, so it comes back at boot with nobody logged in.
#
# It runs on the HOST. This script refuses to install inside a virtual machine,
# because the mini's CI guest is ephemeral and network isolated — a router there
# is unreachable while it exists and gone when the job ends.
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
# lib.sh owns these too, for the same reason it owns the env path: the render
# verb prints the plist that names them, and a second copy here would let the
# printed text and the installed file disagree.
CONF_DIR="$FM_COMMS_CONF_DIR"
LOG_DIR="${FM_COMMS_LOG_DIR:-$FM_COMMS_LOG_DIR_DEFAULT}"
UNIT=fm-zenohd.service
PLIST="/Library/LaunchDaemons/$FM_LAUNCHD_LABEL.plist"

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

# The Linux service path: a systemd unit, enabled and started.
install_unit_linux() {
  fm_log "  installing $UNIT"
  run sudo install -m 0644 "$ROOT/systemd/$UNIT" "/etc/systemd/system/$UNIT"
  run sudo systemctl daemon-reload
  run sudo systemctl enable --now "$UNIT"
  fm_log "  watch it with: journalctl -u $UNIT -f"
}

# The macOS service path: a LaunchDaemon, rendered and bootstrapped.
#
# `launchctl bootstrap system` rather than the deprecated `load`: bootstrap
# reports why a job was refused, where `load` exits 0 on a plist launchd then
# ignores — which is a router that looks installed and is not running.
install_daemon_macos() {
  fm_log "  installing $PLIST"
  run sudo mkdir -p "$LOG_DIR"

  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would write $PLIST:"
    fm_comms_render launchd - || return 1
  else
    local tmp; tmp="$(mktemp)"
    fm_comms_render launchd "$tmp" || { rm -f "$tmp"; return 1; }
    # Owned by root and not group-writable, or launchd refuses to load it.
    sudo install -m 0644 -o root -g wheel "$tmp" "$PLIST"
    rm -f "$tmp"
  fi

  # An existing job holds the port, so it is taken out first. It may legitimately
  # not be loaded, which is not a failure worth stopping the install for.
  run sudo launchctl bootout "system/$FM_LAUNCHD_LABEL" 2>/dev/null || true
  run sudo launchctl bootstrap system "$PLIST"
  fm_log "  watch it with: tail -f $LOG_DIR/zenohd.log"
}

do_install() {
  local os version
  os="$(fm_detect_os)"
  version="$(fm_zenoh_version)"

  # The card decides whether this host belongs on the Zenoh fabric at all. A
  # machine still on dds-lan gets a clear refusal here rather than a second,
  # contradictory transport running beside the one it already speaks.
  fm_comms_require_transport || return 1

  # The router goes on the host, never in the CI guest that shares the machine.
  # A guest is ephemeral and network isolated, so a router there is unreachable
  # while it exists and gone when the job ends — an outage that reads as a fleet
  # fault rather than as a misplaced install.
  if [ "$os" = macos ] && fm_macos_is_vm; then
    fm_err "this looks like a virtual machine, and the router belongs on the host"
    fm_err "  run this on the Mac mini itself, not inside its CI guest"
    fm_err "  set FM_COMMS_ALLOW_VM=1 only if you are certain this host is not a guest"
    [ "${FM_COMMS_ALLOW_VM:-0}" = "1" ] || return 1
    fm_warn "  continuing anyway (FM_COMMS_ALLOW_VM=1)"
  fi

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
    fm_comms_render router - || return 1
  else
    local tmp; tmp="$(mktemp)"
    fm_comms_render router "$tmp"
    sudo install -m 0644 "$tmp" "$CONF_DIR/router.json5"
    rm -f "$tmp"
  fi

  case "$os" in
    linux) install_unit_linux ;;
    macos) install_daemon_macos ;;
  esac

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
  else
    run sudo launchctl bootout "system/$FM_LAUNCHD_LABEL" 2>/dev/null || true
    run sudo rm -f "$PLIST"
    # The logs outlive the job on purpose: the reason a router was removed is
    # usually in them, and this is the moment someone wants to read it.
    fm_log "  left in place: $LOG_DIR"
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
