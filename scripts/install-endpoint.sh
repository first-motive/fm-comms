#!/usr/bin/env bash
#
# install-endpoint.sh — give this machine the fleet's shared facts, and nothing else.
#
# The narrowest role fm-comms has. It places /etc/fm-comms.env and stops: no
# bridge, no unit, no binaries, no config rendered.
#
# It exists for a host that talks to the router without joining a DDS graph. The
# Almond Axol is the first: it has no ROS graph at all — its own stack owns the
# CAN bus, and fm-robot-agent publishes its joint states onto Zenoh directly — so
# a bridge there would be a service with nothing to carry. The agent still needs
# to know where the router is, and that value lives in one file for the whole
# fleet. Without this role that host would either go without the file, or a
# second component would start writing a file fm-comms owns.
#
# The `client` role is not this: a client is a developer's laptop that runs the
# CLI tools and deliberately holds no config.
#
# Runnable standalone or through the front door:
#     ./scripts/install-endpoint.sh [install|uninstall]
#     ./install.sh --role endpoint
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

run() {
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would run: $*"
    return 0
  fi
  "$@"
}

# Place the fleet-wide env file, then stop only if the one value this role exists
# to carry is still missing. An existing file is left exactly as it is: it holds
# the operator's own values, and this role's whole job is to make sure it is
# there rather than to decide what is in it.
place_env() {
  if [ -f "$ENV_FILE" ]; then
    fm_log "  $ENV_FILE exists; leaving it alone"
  else
    fm_log "  placing $ENV_FILE from the example"
    run sudo install -m 0644 "$ROOT/systemd/fm-comms.env.example" "$ENV_FILE"
  fi
  [ "$FM_DRY_RUN" = "1" ] && return 0
  # An unattended run already knows these; a person at a keyboard does not need
  # to be asked twice. Never overwrites a value someone chose.
  fm_comms_env_seed FM_ROUTER_ENDPOINT "${FM_ROUTER_ENDPOINT:-}"
  # Both spellings: this unit exports ROS_DOMAIN_ID from the file, and the
  # rendered config takes the domain from FM_ROS_DOMAIN_ID. The two are kept
  # equal so they cannot drift apart.
  fm_comms_env_seed FM_ROS_DOMAIN_ID "${FM_ROS_DOMAIN_ID:-}"
  fm_comms_env_seed ROS_DOMAIN_ID "${FM_ROS_DOMAIN_ID:-}"
  local missing
  missing="$(fm_comms_env_unfilled FM_ROUTER_ENDPOINT)"
  [ -z "$missing" ] && return 0
  fm_warn "  fill in $ENV_FILE ($missing), then re-run"
  return 1
}

do_install() {
  fm_log "Giving this host the fleet's shared facts (endpoint role)"
  place_env || return 1
  fm_log "  done: $ENV_FILE. No bridge, no unit — this role installs neither."
}

do_uninstall() {
  # Nothing to remove. The env file holds the operator's own values and is shared
  # with every other role, so a role that only ever placed it does not take it
  # away — removing it would break a bridge installed alongside.
  fm_log "Nothing to uninstall for the endpoint role"
  fm_log "  left in place: $ENV_FILE, which the fleet shares"
}

main() {
  case "${1:-install}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    *) fm_err "unknown action '${1:-}' (want install or uninstall)"; return 2 ;;
  esac
}

main "$@"
