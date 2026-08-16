#!/usr/bin/env bash
#
# install-bridge.sh — stand this rig up with a Zenoh ROS 2 bridge.
#
# The bridge joins the rig's local DDS graph and republishes the allowed topics
# onto Zenoh under the rig's namespace. That namespace is derived from this
# machine's identity card and typed nowhere: fm-rec-01 becomes fm_rec_01. Which
# topics cross depends on what work the rig does, which the card does not yet say
# — FM_BRIDGE_PROFILE in /etc/fm-comms.env selects zenoh/bridge-<profile>.json5
# (recorder | processor | robot).
#
# Read the render before installing it:
#     ./run.sh render bridge
#
# Runnable standalone or through the front door:
#     ./scripts/install-bridge.sh [install|uninstall]
#     ./install.sh --role bridge
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
UNIT=fm-zenoh-bridge.service

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
  # Pinned exactly: an unpinned upgrade would drift this rig away from the router
  # and silently drop it off the fleet on a routine apt upgrade.
  run sudo apt-get install -y "zenoh-bridge-ros2dds=$version"
}

place_env() {
  if [ -f "$ENV_FILE" ]; then
    fm_log "  $ENV_FILE exists; leaving it alone"
    return 0
  fi
  fm_log "  placing $ENV_FILE from the example"
  run sudo install -m 0644 "$ROOT/systemd/fm-comms.env.example" "$ENV_FILE"
  fm_warn "  fill in $ENV_FILE (router endpoint, bridge profile), then re-run"
  fm_warn "  the rig's namespace is not in there — it comes from $(fm_machine_file)"
  return 1
}

do_install() {
  local os version
  os="$(fm_detect_os)"
  version="$(fm_zenoh_version)"

  # A bridge belongs on the rig, beside the nodes it bridges. On macOS the stack
  # runs in a container and takes deploy/compose.zenoh.yaml instead — installing
  # a host bridge there would join the Mac's empty DDS graph, not the rig's.
  if [ "$os" != linux ]; then
    fm_err "the bridge role is Linux-only (it must share the rig's DDS graph)"
    fm_err "  on macOS use: ./run.sh compose up -d zenoh-bridge"
    return 1
  fi

  # The card decides whether this rig belongs on the Zenoh fabric at all. A rig
  # still on dds-lan gets a clear refusal here rather than a second, contradictory
  # transport running beside the one it already speaks.
  fm_comms_require_transport || return 1

  fm_log "Installing the Zenoh ROS 2 bridge (zenoh $version) on $os"
  install_linux "$version"

  place_env || return 0

  fm_log "  rendering $CONF_DIR/bridge.json5"
  run sudo mkdir -p "$CONF_DIR"
  if [ "$FM_DRY_RUN" = "1" ]; then
    # Print the config rather than describing it: a dry run whose only output is
    # "would render X" cannot catch the mistake the render itself would make —
    # an empty namespace or an endpoint nobody filled in are both visible here.
    fm_log "  would write $CONF_DIR/bridge.json5:"
    fm_comms_render bridge -
  else
    local tmp; tmp="$(mktemp)"
    fm_comms_render bridge "$tmp"
    sudo install -m 0644 "$tmp" "$CONF_DIR/bridge.json5"
    rm -f "$tmp"
  fi

  fm_log "  installing $UNIT"
  run sudo install -m 0644 "$ROOT/systemd/$UNIT" "/etc/systemd/system/$UNIT"
  run sudo systemctl daemon-reload
  run sudo systemctl enable --now "$UNIT"
  fm_log "  watch it with: journalctl -u $UNIT -f"

  fm_ok "bridge install complete."
}

do_uninstall() {
  fm_log "Removing the Zenoh ROS 2 bridge"
  run sudo systemctl disable --now "$UNIT" || true
  run sudo rm -f "/etc/systemd/system/$UNIT"
  run sudo systemctl daemon-reload
  # Only what this script placed. $ENV_FILE holds the operator's own values, so
  # it survives an uninstall and a later reinstall picks it back up.
  run sudo rm -f "$CONF_DIR/bridge.json5"
  fm_log "  left in place: $ENV_FILE and the zenoh-bridge-ros2dds package"
  fm_ok "bridge uninstall complete."
}

main() {
  case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *) fm_err "usage: $0 [install|uninstall]"; return 1 ;;
  esac
}

main "$@"
