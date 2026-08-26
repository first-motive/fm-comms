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
  fm_install_zenohd_macos "$1"
}

# Place the fleet-wide env file, then stop only if a value this role needs is
# still missing — which, for a router, is none of them.
#
# The old version stopped on any first placement, so the first run of the router
# installer always failed and pre-placing the file by hand was the workaround
# (fm-comms#17, Rune, 2026-08-26). Nothing in the example is a router's to fill:
# the port has a default and both bind addresses are read off the host. What a
# bridge needs is FM_ROUTER_ENDPOINT, and that is checked in its own installer.
place_env() {
  if [ -f "$ENV_FILE" ]; then
    fm_log "  $ENV_FILE exists; leaving it alone"
  else
    fm_log "  placing $ENV_FILE from the example"
    run sudo install -m 0644 "$ROOT/systemd/fm-comms.env.example" "$ENV_FILE"
  fi
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

# Check what the router actually bound, not whether the service manager exited 0.
#
# The install can succeed and the socket still be wrong: a stale config left over
# from before the LAN endpoint was added, a tailnet that was not up when zenohd
# started, a wildcard someone put in FM_ROUTER_LISTEN by hand. Each of those is a
# fleet-wide fault that reads as a network problem days later, and each is
# visible here in a couple of connections.
#
# The check CONNECTS to each endpoint rather than looking for the port in a
# socket table. That is what a bridge does, and it is the only form of the
# question that survives macOS: `lsof -i` run by anyone but the socket's owner
# lists nothing there, and the router's LaunchDaemon does not run as the account
# installing it — which is how this reported "nothing is listening" while zenohd
# was up on both addresses (fm-comms#20). Both addresses, one at a time, so a
# router that came up on the tailnet and missed the LAN is named as that rather
# than as a pass.
#
# The socket table is still read afterwards, privileged, for the one thing a
# connection cannot see: an extra or wildcard listener. A host that will not show
# it says so and the install continues — the wildcard is already refused at
# render time and in CI, and a check that cannot run must not masquerade as one
# that passed.
verify_listeners() {
  local port="${FM_ROUTER_PORT:-7447}" want listeners endpoint addr pending
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would check that zenohd answers on:"
    fm_router_listen_list | sed 's/^/    /'
    return 0
  fi
  want="$(fm_router_listen_list)" || return 1

  # zenohd binds after launchd or systemd has started it, not before.
  local waited=0
  while :; do
    pending=""
    while IFS= read -r endpoint; do
      [ -n "$endpoint" ] || continue
      addr="${endpoint#tcp/}"
      addr="${addr%:*}"
      fm_tcp_listening "$addr" "$port" || pending="${pending:+$pending }$endpoint"
    done <<EOF
$want
EOF
    [ -z "$pending" ] && break
    [ "$waited" -ge 15 ] && break
    sleep 1
    waited=$((waited + 1))
  done

  if [ -n "$pending" ]; then
    fm_err "the router is not answering on: $pending (after ${waited}s)"
    fm_err "  read the log: $LOG_DIR/zenohd.err.log (macOS) or journalctl -u $UNIT (linux)"
    listeners="$(fm_tcp_listeners "$port")"
    [ -n "$listeners" ] && printf '%s\n' "$listeners" >&2
    return 1
  fi

  listeners="$(fm_tcp_listeners "$port")"
  if [ -z "$listeners" ]; then
    fm_warn "  could not read this host's socket table, so nothing checked for an extra listener"
    fm_warn "  see them yourself with: sudo lsof -nP -iTCP:$port -sTCP:LISTEN"
  elif printf '%s' "$listeners" | grep -qE '(\*|0\.0\.0\.0|\[::\]):'"$port"; then
    fm_err "the router is bound to every interface; it must bind the LAN and the tailnet only"
    printf '%s\n' "$listeners" >&2
    return 1
  fi

  fm_log "  answering on:"
  printf '%s\n' "$want" | sed 's/^/    /'
  # Explicit, so the function's exit status is the verdict of the check and not
  # whatever the last line of formatting returned.
  return 0
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

  place_env

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

  verify_listeners || return 1

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
