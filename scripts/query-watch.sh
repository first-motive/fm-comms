#!/usr/bin/env bash
#
# query-watch.sh — bounded diagnostic for Zenoh query timeouts on the router.
#
# The router log records query timeouts as:
#   WARN ... REQUESTER_SESSION Didn't receive final reply for query
#            RESPONDER_SESSION: Timeout(5s)!
# but does NOT log the key expression. This script collects the session IDs,
# cross-references them with connected peer IPs (from netstat/lsof), and
# watches for new timeouts to identify the requesting application.
#
# Usage:
#   ./run.sh query-watch              show known timeout pairs from current log
#   ./run.sh query-watch --live       tail the log for new events (Ctrl-C to stop)
#
# What it cannot do on the router alone:
# - identify the keyexpr (the router log format does not include it in the
#   warning; it appears only in lower-level debug logging, not enabled here)
# - name the application (only the Zenoh session ID and the peer IP are visible)
# - confirm whether the responder is supposed to exist (needs knowledge of fleet
#   topology at the time of the query)
#
# To get the keyexpr: enable zenohd debug logging on the next fleet session
# by adding RUST_LOG=debug to the router environment and capturing the output.
# This produces very high log volume and should be time-bounded.
#
# Status: INVESTIGATION IN PROGRESS. Cause of query timeouts unknown.
# The 24 timeouts seen in the old log span 7 dates and 8 distinct session pairs.
# This does not fit a single missing service; it may be normal Zenoh reconnect
# behaviour during topology changes, or multiple callers with unregistered
# queryables. Fleet machines need to be online and reachable for confirmation.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh disable=SC1091
. "$ROOT/lib.sh"

LOG_DIR="${FM_COMMS_LOG_DIR:-$FM_COMMS_LOG_DIR_DEFAULT}"
LOG_FILE="$LOG_DIR/zenohd.log"
PORT="${FM_ROUTER_PORT:-7447}"

LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

# --- session ID → IP mapping --------------------------------------------------
# Maps Zenoh session IDs to peer IPs using the router's current connection table.
# Sessions open/close frequently; this snapshot is valid only at query time.
peer_map() {
  netstat -an -p tcp 2>/dev/null \
    | awk -v port=":$PORT" '$6=="ESTABLISHED" && $4 ~ port {sub(/.*:/,""); print $5}' \
    | sort -u \
    | sed 's/:.*//'
}

# --- known timeout pairs from log ---------------------------------------------
show_known() {
  if [ ! -r "$LOG_FILE" ]; then
    printf 'log not readable: %s\n' "$LOG_FILE" >&2
    return 1
  fi

  printf '\n=== Query timeout pairs in current log ===\n\n'
  printf '  %-8s %-12s  %-12s  %s\n' "count" "requester" "responder" "last seen"

  grep "Didn't receive final reply" "$LOG_FILE" 2>/dev/null \
    | awk '{
        for(i=1;i<=NF;i++){
          if($i ~ /^south:0:client\//) {
            if(req=="") req=$i
            else if($i!=req) resp=$i
          }
        }
        ts=substr($1,1,19)
        key=req"→"resp
        count[key]++
        last[key]=ts
        req=""; resp=""
      }
      END {
        for(k in count) printf "%8d  %s  %s\n", count[k], k, last[k]
      }' \
    | sort -rn \
    | while IFS= read -r line; do
        count=$(printf '%s' "$line" | awk '{print $1}')
        pair=$(printf '%s' "$line" | awk '{print $2}')
        ts=$(printf '%s' "$line" | awk '{print $3}')
        req=$(printf '%s' "$pair" | cut -d'→' -f1 | sed 's/south:0:client\///' | cut -d: -f1)
        resp=$(printf '%s' "$pair" | cut -d'→' -f2 | sed 's/south:0:client\///' | cut -d: -f1)
        printf '  %-8s %-12s  %-12s  %s\n' "$count" "$req" "$resp" "$ts"
      done

  printf '\nNote: session IDs are Zenoh-internal. IP→session mapping is not retained.\n'
  printf 'The key expression is NOT in the warning log; run with --live and\n'
  printf 'enable RUST_LOG=debug to capture it when the next timeout occurs.\n\n'

  printf '=== Currently connected peer IPs ===\n'
  peers=$(peer_map)
  if [ -n "$peers" ]; then
    printf '%s\n' "$peers" | sed 's/^/  /'
  else
    printf '  (none or not readable without sudo)\n'
  fi
  printf '\n'
}

# --- live watch ---------------------------------------------------------------
watch_live() {
  if [ ! -r "$LOG_FILE" ]; then
    printf 'log not readable: %s\n' "$LOG_FILE" >&2
    return 1
  fi
  printf 'Watching %s for query timeouts (Ctrl-C to stop)...\n\n' "$LOG_FILE"
  tail -f "$LOG_FILE" 2>/dev/null \
    | grep --line-buffered "Didn't receive final reply\|Query not found\|Route reply" \
    | while IFS= read -r line; do
        ts=$(date +%H:%M:%S)
        printf '[%s] %s\n' "$ts" "$line"
        # Show current peers at each event for correlation
        peers=$(peer_map)
        [ -n "$peers" ] && printf '  peers: %s\n' "$(printf '%s' "$peers" | tr '\n' ' ')"
      done
}

# --- dispatch -----------------------------------------------------------------
fm_banner
if [ "$LIVE" = "1" ]; then
  watch_live
else
  show_known
fi
