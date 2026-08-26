#!/usr/bin/env bash
#
# render.sh — print this host's rendered config, without installing anything.
#
# Rendering is where a new rig goes wrong: a namespace that came out empty, a
# router endpoint nobody filled in, a card the host does not have. Every one of
# those is obvious in the rendered text and invisible in a service that started
# and then sat there routing nothing — so the same render the installers write is
# available here to read first.
#
#     ./run.sh render bridge            what /etc/fm-comms/bridge.json5 would be
#     ./run.sh render router            what /etc/fm-comms/router.json5 would be
#     ./run.sh render launchd           the router's macOS LaunchDaemon plist
#     ./run.sh render launchagent       the Mac bridge's LaunchAgent plist
#     ./run.sh render episodes          what the episodes unit would be
#     ./run.sh render show              the host facts every render resolves from
#     ./run.sh render bridge -o out.json5
#
# The per-host values come from this machine's identity card (/etc/fm/machine.json
# on Linux, ~/.config/fm/machine.json on macOS, $FM_MACHINE_FILE anywhere), which
# fm-setup writes. The fleet-wide values come from /etc/fm-comms.env. Point
# FM_MACHINE_FILE and FM_COMMS_ENV_FILE at a pair of files to rehearse another
# host's render from a laptop.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh disable=SC1091
. "$ROOT/lib.sh"

usage() {
  cat <<'EOF'
render — print this host's config as the installers would write it

Usage: ./run.sh render <what> [-o FILE]

  router       the zenohd config
  launchd      the router's macOS LaunchDaemon plist
  bridge       the ROS 2 bridge config for this machine's workload
  launchagent  the Mac bridge's LaunchAgent plist
  episodes     the episode queryable's systemd unit
  show         the resolved host facts, one per line

Options:
  -o, --output FILE   write there instead of stdout
  -h, --help          this text

Env: FM_MACHINE_FILE, FM_COMMS_ENV_FILE (see the header comment)
EOF
}

# Print what the render resolved and where each value came from. Answers the
# question an operator actually has — "is this rig reading the card I think it
# is?" — without them having to read three files and a JSON schema.
show() {
  local card
  fm_comms_resolve || return 1
  if fm_machine_exists; then
    card="$(fm_machine_file)"
    fm_log "identity card   $card"
    fm_log "  name          $(fm_machine_get name)"
    fm_log "  role          $(fm_machine_get role)"
    fm_log "  fleet         $(fm_machine_get fleet)"
    fm_log "  transport     $(fm_machine_get transport)"
    fm_log "  workload      $(fm_machine_get_opt workload || true)"
    fm_log "  workspace     $(fm_machine_get workspace)"
  else
    fm_warn "no identity card at $(fm_machine_file) — per-host values must come from the environment"
  fi
  fm_log "resolved"
  fm_log "  namespace     ${FM_RIG_NAMESPACE:-<unset>}"
  # Derived, so it is resolved here rather than echoed back from the environment
  # — the whole point of `show` is to prove what this host WOULD render, and an
  # unset variable says nothing about the card the profile now comes from.
  fm_log "  profile       $(fm_comms_bridge_profile 2>/dev/null || echo '<none — this host runs no bridge>')"
  # The template beside the profile, because the two can disagree: a card naming
  # a workload this checkout carries no config for is the failure that reads as
  # "the bridge started and routed nothing".
  fm_log "  template      $(fm_comms_bridge_template 2>/dev/null || echo '<none>')"
  fm_log "  router        ${FM_ROUTER_ENDPOINT:-<unset>}"
  fm_log "  router port   ${FM_ROUTER_PORT:-<unset>}"
  # The bind addresses only matter on the router itself, and resolving them needs
  # a LAN interface and a tailnet — so they are reported when they resolve and
  # named as absent when they do not, rather than failing a `render show` run from
  # a laptop. Two of them on a router: the LAN address and the tailnet address.
  local listen
  if listen="$(fm_router_listen_list 2>/dev/null)" && [ -n "$listen" ]; then
    fm_log "  router listen $(printf '%s' "$listen" | paste -sd' ' -)"
  else
    fm_log "  router listen <this host resolves no LAN + tailnet pair>"
  fi
  fm_log "  ROS domain    ${FM_ROS_DOMAIN_ID:-<unset>}"
  fm_log "  episodes dir  ${FM_EPISODES_DIR:-<unset>}"
}

main() {
  local what="" dest="-"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o|--output) shift; dest="${1:-}" ;;
      --output=*)  dest="${1#--output=}" ;;
      -h|--help)   usage; return 0 ;;
      -*) fm_err "unknown option: $1"; usage; return 1 ;;
      *)  what="$1" ;;
    esac
    shift
  done

  if [ -z "$what" ]; then
    usage
    return 1
  fi

  case "$what" in
    show) show ;;
    router|launchd|launchagent|bridge|episodes) fm_comms_render "$what" "$dest" ;;
    *) fm_err "unknown render target: $what"; usage; return 1 ;;
  esac
}

main "$@"
