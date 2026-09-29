#!/usr/bin/env bash
#
# router-health.sh — read-only health check for the Zenoh router.
#
# All checks are read-only. No change is made to the router or its config.
# Exits 0 when every check passes (warn does not fail the exit), non-zero on any fail.
#
#     ./run.sh router-health           print a table of checks
#     ./run.sh router-health --json    emit machine-readable JSON
#
# Env:
#   FM_HEALTH_JSON=1   same as --json
#   FM_COMMS_LOG_DIR   where zenohd.log lives (default: /usr/local/var/log/fm-comms)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh disable=SC1091
. "$ROOT/lib.sh"

LOG_DIR="${FM_COMMS_LOG_DIR:-$FM_COMMS_LOG_DIR_DEFAULT}"
LOG_FILE="$LOG_DIR/zenohd.log"
LABEL="$FM_LAUNCHD_LABEL"

JSON="${FM_HEALTH_JSON:-0}"
[ "${1:-}" = "--json" ] && JSON=1

# --- result accumulator ------------------------------------------------------

PASS=0
FAIL=0
WARN=0
declare -a ROWS=()

result() {
  local status="$1" name="$2" detail="$3"
  case "$status" in
    pass) PASS=$((PASS+1)) ;;
    fail) FAIL=$((FAIL+1)) ;;
    warn) WARN=$((WARN+1)) ;;
    unavailable) WARN=$((WARN+1)) ;;
  esac
  ROWS+=("{\"status\":\"$status\",\"check\":$(printf '%s' "$name" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'),\"detail\":$(printf '%s' "$detail" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}")
}

# --- 1. Process running -------------------------------------------------------

pid=""
pid=$(pgrep -d ' ' -f "zenohd.*router.json5" 2>/dev/null | awk '{print $1}') || true
if [ -n "$pid" ]; then
  uptime_secs=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || uptime_secs="?"
  result pass "process" "pid=$pid uptime=${uptime_secs}s"
else
  result fail "process" "zenohd not running (label: $LABEL)"
fi

# --- 2. launchd state ---------------------------------------------------------
# sudo -n launchctl succeeds in a TTY session even as an unprivileged user.
# Parse the 'state' field; if the output is empty (sudo denied or service absent)
# report it as unavailable rather than masking a possible failure.

launchd_out=""
# launchctl print system/<label> does not require sudo on macOS for system services.
# Try without sudo first; fall back to sudo -n for cases where policy requires it.
launchd_out=$(launchctl print "system/$LABEL" 2>/dev/null) \
  || launchd_out=$(sudo -n launchctl print "system/$LABEL" 2>/dev/null) \
  || true
state=""
if [ -n "$launchd_out" ]; then
  # Use [[:space:]] not \s — macOS awk does not treat \s as a character class
  state=$(printf '%s' "$launchd_out" | awk '/^[[:space:]]*state = /{print $3; exit}')
fi
if [ "$state" = "running" ]; then
  result pass "launchd" "state=running"
elif [ -n "$state" ]; then
  result fail "launchd" "state=$state"
else
  result unavailable "launchd" "launchctl print returned nothing (sudo -n denied or service absent)"
fi

# --- 3. Version: running executable vs pin ------------------------------------
# Check the executable that the running process opened (via /proc or lsof),
# not just the binary sitting at /usr/local/bin/zenohd.

pinned=$(fm_zenoh_version 2>/dev/null) || pinned="?"

# First check the canonical install path
canonical_bin=/usr/local/bin/zenohd
canonical_ver=""
if [ -x "$canonical_bin" ]; then
  canonical_ver=$("$canonical_bin" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
fi

# Also check the actual running executable via the process fd (macOS: lsof txt)
running_exe=""
if [ -n "$pid" ]; then
  running_exe=$(sudo -n lsof -p "$pid" 2>/dev/null | awk '/txt.*zenohd$/{print $NF}' | head -1) || true
fi

if [ -z "$running_exe" ] && [ -n "$pid" ]; then
  # Fallback: check the process cmd path
  running_exe=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ') || true
fi

if [ -n "$running_exe" ] && [ "$running_exe" != "$canonical_bin" ]; then
  result fail "version" "running from $running_exe, expected $canonical_bin"
elif [ -n "$canonical_ver" ] && [ "$canonical_ver" = "$pinned" ]; then
  note=""
  [ -n "$running_exe" ] && note=" (exe=$running_exe)"
  result pass "version" "$canonical_ver (matches pin)$note"
elif [ -z "$canonical_ver" ]; then
  result warn "version" "could not read version from $canonical_bin (quarantine?)"
else
  result fail "version" "on-disk=$canonical_ver pinned=$pinned"
fi

# --- 4. Both listeners active --------------------------------------------------

port="${FM_ROUTER_PORT:-7447}"
want=$(fm_router_listen_list 2>/dev/null) || want=""

if [ -z "$want" ]; then
  result warn "listeners" "cannot resolve expected listeners (LAN or tailnet unavailable)"
else
  all_ok=1
  details=""
  while IFS= read -r ep; do
    [ -n "$ep" ] || continue
    addr="${ep#tcp/}"; addr="${addr%:*}"
    if fm_tcp_listening "$addr" "$port"; then
      details="${details}${details:+, }$ep=ok"
    else
      details="${details}${details:+, }$ep=FAIL"
      all_ok=0
    fi
  done <<EOF
$want
EOF
  if [ "$all_ok" = "1" ]; then
    result pass "listeners" "$details"
  else
    result fail "listeners" "$details"
  fi
fi

# --- 5. No wildcard listener --------------------------------------------------

wild=""
if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
   || sudo -n lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
  wild=$(sudo -n lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null \
         || lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  wild=$(printf '%s' "$wild" | grep -E '(\*|0\.0\.0\.0|\[::\]):'"$port") || wild=""
  if [ -n "$wild" ]; then
    result fail "no-wildcard" "router is bound to every interface — this exposes the fleet"
  else
    result pass "no-wildcard" "no wildcard listener"
  fi
else
  result unavailable "no-wildcard" "socket table not readable (sudo -n denied)"
fi

# --- 6. Service account not root ----------------------------------------------

if [ -n "$pid" ]; then
  proc_user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ') || proc_user=""
  if [ "$proc_user" = "root" ]; then
    result fail "service-account" "running as root — should run as fm"
  elif [ -n "$proc_user" ]; then
    result pass "service-account" "user=$proc_user"
  else
    result warn "service-account" "could not read process user"
  fi
else
  result warn "service-account" "process not running, cannot check"
fi

# --- 7. Log file accessible and below rotation threshold ----------------------
# 200 MB is the newsyslog rotation threshold, not a hard ceiling.
# The file may exceed it between rotation runs.

if [ -r "$LOG_FILE" ]; then
  size_bytes=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  size_mb=$(python3 -c "print(f'{$size_bytes/1048576:.1f}')" 2>/dev/null || echo "?")
  if [ "$size_bytes" -gt 209715200 ]; then
    result warn "log-size" "${size_mb} MB — above 200 MB rotation threshold (rotation pending)"
  else
    result pass "log-size" "${size_mb} MB"
  fi
  # Permission: should be 640 (owner read/write, group read, world none)
  perms=$(stat -f%Lp "$LOG_FILE" 2>/dev/null || echo "?")
  if [ "$perms" = "640" ]; then
    result pass "log-perms" "mode 640"
  else
    result warn "log-perms" "mode $perms (expected 640)"
  fi
elif [ -e "$LOG_FILE" ]; then
  result unavailable "log-size" "log exists but is not readable by this user"
  result unavailable "log-perms" "log exists but is not readable by this user"
else
  result unavailable "log-size" "log not found at $LOG_FILE"
  result unavailable "log-perms" "log not found at $LOG_FILE"
fi

# --- 8. Clock (NTP): measure with multiple probes ----------------------------
# An sntp reply from a stratum-2 server is not proof that macOS timed is
# synchronized. We measure offset and report uncertainty.
# Warn on timeout; warn on high offset; note uncertainty in the detail.

ntp_pass=0
ntp_fail=0
ntp_offsets=()
for attempt in 1 2 3; do
  probe=$(sntp -t 2 time.apple.com 2>/dev/null) || { ntp_fail=$((ntp_fail+1)); continue; }
  off=$(printf '%s' "$probe" | grep -oE '^[+-][0-9]+\.[0-9]+') || { ntp_fail=$((ntp_fail+1)); continue; }
  ntp_offsets+=("$off")
  ntp_pass=$((ntp_pass+1))
done

if [ ${#ntp_offsets[@]} -eq 0 ]; then
  result warn "clock" "all $ntp_fail sntp probes timed out — NTP state unknown"
else
  # Use the first successful probe offset (nearest-recent)
  offset="${ntp_offsets[0]}"
  abs_offset=$(python3 -c "print(abs($offset))" 2>/dev/null || echo "9")
  ok=$(python3 -c "print('yes' if abs($offset) < 0.1 else 'no')" 2>/dev/null || echo "no")
  extra=""
  [ "$ntp_fail" -gt 0 ] && extra=" ($ntp_fail/$((ntp_pass+ntp_fail)) probes timed out)"
  # Note: offset alone does not confirm timed is synced; also check com.apple.timed state
  timed_state=$(launchctl print system/com.apple.timed 2>/dev/null | awk '/^[[:space:]]*state = /{print $3; exit}') \
    || timed_state=$(sudo -n launchctl print system/com.apple.timed 2>/dev/null | awk '/^[[:space:]]*state = /{print $3; exit}') \
    || timed_state=""
  timed_note=""
  [ -n "$timed_state" ] && timed_note=" timed=$timed_state"
  if [ "$ok" = "yes" ]; then
    result pass "clock" "offset=${offset}s vs time.apple.com${timed_note}${extra}"
  else
    result warn "clock" "offset=${offset}s (>100ms; Zenoh 500ms budget partially consumed)${timed_note}${extra}"
  fi
fi

# --- 9. Timestamp replacement count ------------------------------------------
# Reports counts for the current log only; a fresh log after a restart starts at 0.
# High counts indicate one or more publishers with clocks out of sync with the router.
# The cause (publisher drift, router drift, or both) is not determined here.

ts_count=0
qt_count=0
qt_qnf=0
log_readable=0
if [ -r "$LOG_FILE" ]; then
  log_readable=1
  ts_count=$(grep -c "exceeding delta" "$LOG_FILE" 2>/dev/null || true)
  ts_count="${ts_count:-0}"
  qt_count=$(grep -c "Didn't receive final reply" "$LOG_FILE" 2>/dev/null || true)
  qt_count="${qt_count:-0}"
  qt_qnf=$(grep -c "Query not found!" "$LOG_FILE" 2>/dev/null || true)
  qt_qnf="${qt_qnf:-0}"
fi

if [ "$log_readable" -eq 0 ]; then
  result unavailable "ts-replacements" "log not readable"
  result unavailable "query-timeouts" "log not readable"
else
  if [ "$ts_count" -gt 10000 ]; then
    result warn "ts-replacements" "${ts_count} in current log (cause unconfirmed; check publisher and router clock sync)"
  else
    result pass "ts-replacements" "${ts_count} (observation window: since last restart only)"
  fi

  # query-timeouts: report count without claiming a cause
  if [ "$qt_count" -gt 50 ]; then
    result warn "query-timeouts" "${qt_count} final-reply timeouts, ${qt_qnf} not-found (requester/key/responder unidentified)"
  else
    result pass "query-timeouts" "${qt_count} final-reply timeouts, ${qt_qnf} not-found (current log only)"
  fi
fi

# --- output ------------------------------------------------------------------

if [ "$JSON" = "1" ]; then
  python3 - "$PASS" "$WARN" "$FAIL" "${ROWS[@]}" <<'PY'
import json, sys
pass_, warn, fail = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
rows = [json.loads(r) for r in sys.argv[4:]]
print(json.dumps({"pass": pass_, "warn": warn, "fail": fail, "checks": rows}, indent=2))
PY
else
  fm_banner
  printf '\n  %-20s %-6s %s\n' "check" "status" "detail"
  printf '  %-20s %-6s %s\n' "$(printf '%0.s-' {1..20})" "------" "$(printf '%0.s-' {1..40})"
  for row in "${ROWS[@]}"; do
    name=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['check'])" "$row")
    status=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['status'])" "$row")
    detail=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['detail'])" "$row")
    case "$status" in
      pass)        sym="✓" ;;
      fail)        sym="✗" ;;
      warn)        sym="!" ;;
      unavailable) sym="?" ;;
      *)           sym="?" ;;
    esac
    printf '  %-20s %s %-11s %s\n' "$name" "$sym" "$status" "$detail"
  done
  printf '\n  %d pass  %d warn  %d fail\n' "$PASS" "$WARN" "$FAIL"
fi

[ "$FAIL" -eq 0 ]
