#!/usr/bin/env bash
#
# smoke-transport.sh — prove a bridge and a router at the pinned version actually
# form a session.
#
# The check every other test in this repo cannot make: the configs render, they
# parse, they satisfy the invariants — and none of that says the two processes
# agree on the wire. A version gap between a router and a bridge is exactly the
# failure the single version pin exists to prevent, and it shows up here.
#
# It asserts state, not a timeout. The router's REST plugin serves its admin
# space, so this asks the router which sessions it holds and fails when the
# answer is none. A smoke that only proved a container stayed up for 30 seconds
# would pass with a bridge that never connected.
#
#   ./scripts/ci/smoke-transport.sh
#
# Needs docker and a network that can pull the two eclipse/zenoh images.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$ROOT/lib.sh"

COMPOSE_FILE="$ROOT/scripts/ci/compose.smoke.yaml"
PROJECT=fm-comms-smoke
DEADLINE_SECONDS="${FM_SMOKE_DEADLINE:-90}"

WORKDIR=""
cleanup() {
  if [ -n "$WORKDIR" ]; then
    # Logs first: on a failure they are the only account of what the two
    # processes did, and compose down takes them with it.
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" logs --no-color 2>/dev/null | tail -60 || true
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

# Render the real templates against a fixture card, into a scratch directory the
# two containers mount. Rendering rather than hand-writing is the point: this
# smoke runs the configuration the rigs run, not a simplified copy of it.
render_configs() {
  local conf="$WORKDIR/conf"
  mkdir -p "$conf"

  cat >"$WORKDIR/machine.json" <<'JSON'
{
  "schema_version": 1,
  "name": "fm-rec-01",
  "role": "jetson",
  "fleet": "smoke",
  "transport": "zenoh",
  "workload": "recorder",
  "workspace": "/home/fm/fm"
}
JSON

  # The router's endpoint is the compose service name: the two containers share a
  # private network, and the bridge resolves the router by that name.
  cat >"$WORKDIR/fm-comms.env" <<'ENV'
FM_ROUTER_PORT=7447
FM_ROUTER_ENDPOINT=tcp/zenoh-router:7447
FM_ROS_DOMAIN_ID=0
ENV

  # 0.0.0.0 here, and only here. A real router binds its tailnet address and the
  # invariant check fails a wildcard — but a container does not know its own
  # address before it starts, and the network it is on is private to this run.
  FM_MACHINE_FILE="$WORKDIR/machine.json" \
  FM_COMMS_ENV_FILE="$WORKDIR/fm-comms.env" \
  FM_ROUTER_BIND_IP=0.0.0.0 \
    "$ROOT/run.sh" render router -o "$conf/router.json5" >/dev/null

  FM_MACHINE_FILE="$WORKDIR/machine.json" \
  FM_COMMS_ENV_FILE="$WORKDIR/fm-comms.env" \
    "$ROOT/run.sh" render bridge -o "$conf/bridge.json5" >/dev/null

  chmod -R a+r "$conf"
  printf '%s\n' "$conf"
}

# Ask the router how many sessions it holds. Zero until the bridge connects.
router_session_count() {
  local body
  body="$(curl -fsS --max-time 5 'http://127.0.0.1:8000/@/local/router' 2>/dev/null)" || return 1
  # The admin reply is an array of one entry whose value carries `sessions`. jq
  # counts them rather than the script grepping for a substring, so a reply that
  # changed shape fails loudly instead of matching by accident.
  printf '%s' "$body" | jq -e '[.. | objects | select(has("sessions")) | .sessions[]] | length' 2>/dev/null
}

main() {
  fm_require_cmd docker
  fm_require_cmd jq
  fm_require_cmd curl

  local version conf waited=0 count
  version="$(fm_zenoh_version)"
  fm_log "Zenoh transport smoke (zenoh $version)"

  WORKDIR="$(mktemp -d)"
  conf="$(render_configs)"
  fm_log "  rendered router.json5 and bridge.json5 into $conf"

  FM_ZENOH_VERSION="$version" FM_SMOKE_CONF="$conf" \
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d --quiet-pull

  fm_log "  waiting for the bridge to establish a session with the router"
  while [ "$waited" -lt "$DEADLINE_SECONDS" ]; do
    if count="$(router_session_count)" && [ "${count:-0}" -gt 0 ]; then
      fm_ok "router holds $count session(s) — bridge and router agree at zenoh $version"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  fm_err "no session after ${DEADLINE_SECONDS}s — the bridge never reached the router"
  fm_err "  a router and a bridge at different versions fail exactly like this"
  return 1
}

main "$@"
