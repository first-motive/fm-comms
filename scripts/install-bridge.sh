#!/usr/bin/env bash
#
# install-bridge.sh — stand this rig up with a Zenoh ROS 2 bridge.
#
# The bridge joins the rig's local DDS graph and republishes the allowed topics
# onto Zenoh under the rig's namespace. Which topics those are depends on what
# the rig is: FM_BRIDGE_PROFILE in /etc/fm-comms.env selects
# zenoh/bridge-<profile>.json5 (recorder | processor | robot).
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

ENV_FILE=/etc/fm-comms.env
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
  fm_warn "  fill in $ENV_FILE (router endpoint, rig namespace, profile), then re-run"
  return 1
}

do_install() {
  local os version profile template
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

  fm_log "Installing the Zenoh ROS 2 bridge (zenoh $version) on $os"
  install_linux "$version"

  place_env || return 0

  # shellcheck source=/dev/null
  [ "$FM_DRY_RUN" = "1" ] || . "$ENV_FILE"
  profile="${FM_BRIDGE_PROFILE:-}"
  if [ "$FM_DRY_RUN" != "1" ]; then
    if ! printf '%s' "$profile" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
      fm_err "FM_BRIDGE_PROFILE is unset or malformed in $ENV_FILE (want recorder | processor | robot)"
      return 1
    fi
    template="$ROOT/zenoh/bridge-$profile.json5"
    if [ ! -f "$template" ]; then
      local known=() candidate name
      for candidate in "$ROOT"/zenoh/bridge-*.json5; do
        [ -f "$candidate" ] || continue
        name="${candidate##*/bridge-}"
        known+=("${name%.json5}")
      done
      fm_err "no config for profile '$profile'"
      fm_err "  profiles this checkout carries: ${known[*]}"
      return 1
    fi
  fi

  fm_log "  rendering $CONF_DIR/bridge.json5 from the $profile profile"
  run sudo mkdir -p "$CONF_DIR"
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would render $ROOT/zenoh/bridge-<profile>.json5 -> $CONF_DIR/bridge.json5"
  else
    local tmp; tmp="$(mktemp)"
    fm_render_template "$template" "$tmp" \
      FM_ROUTER_ENDPOINT FM_RIG_NAMESPACE FM_ROS_DOMAIN_ID
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
