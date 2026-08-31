#!/usr/bin/env bash
# The macOS bridge install, in the three ways it was found broken (2026-08-31).
#
#   ./scripts/ci/test-macos-bridge-install.sh
#
# Dry-run only: renders nothing, loads nothing, touches no launchd domain.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf 'FM_ROUTER_ENDPOINT=tcp/100.111.147.125:7447\n' > "$WORK/tailnet.env"
printf 'FM_ROUTER_ENDPOINT=tcp/192.168.1.213:7447\n'   > "$WORK/lan.env"

# --dry-run, not FM_DRY_RUN=1: the front door SETS that variable from the flag,
# so exporting it is silently ignored and the install runs for real. Sandboxed
# HOME as well, so a mistake here cannot reach the machine running the test.
run_install() {  # env-file
  local home
  home="$WORK/home"
  mkdir -p "$home/.config/fm" "$home/Library/LaunchAgents"
  cp "${FM_MACHINE_FILE:-$HOME/.config/fm/machine.json}" "$home/.config/fm/" 2>/dev/null || true
  HOME="$home" FM_COMMS_ENV_FILE="$1" ./install.sh --role bridge --dry-run 2>&1
}

echo "== a LAN endpoint on macOS is called out before it fails =="
# macOS refuses a LaunchAgent's connections to private LAN addresses (Local
# Network privacy) with EHOSTUNREACH, and the bridge dies at start with a message
# that reads as a network fault. The install is the only place to say so.
lan_out="$(run_install "$WORK/lan.env")"
if grep -qi "local network" <<<"$lan_out"; then
  pass "a private LAN endpoint warns about Local Network privacy"
else
  fail "a private LAN endpoint installs silently — the bridge will die with 'No route to host'"
  printf '%s\n' "$lan_out" | tail -4 | sed 's/^/       /'
fi

rm -rf "${WORK:?}/home"
tailnet_out="$(run_install "$WORK/tailnet.env")"
if grep -qi "local network" <<<"$tailnet_out"; then
  fail "a tailnet endpoint warns when it has no reason to"
else
  pass "a tailnet endpoint is left alone"
fi

echo "== launchctl addresses the agent's owner, never gui/0 =="
# These greps look for literal shell text in the installer, so the patterns are
# deliberately unexpanded.
# shellcheck disable=SC2016
# Run under sudo — which the Linux path needs — `id -u` is 0 and every launchctl
# call lands on gui/0, which launchd refuses outright:
#   Bootstrap failed: 125: Domain does not support specified action
# shellcheck disable=SC2016  # a literal pattern, not an expansion
if grep -q 'gui/\$(id -u)' scripts/install-bridge.sh; then
  fail "a launchctl call still uses gui/\$(id -u) — that is gui/0 under sudo"
else
  pass "no launchctl call derives its domain from the running uid"
fi
# shellcheck disable=SC2016  # a literal pattern, not an expansion
if grep -q 'FM_AGENT_USER="\${SUDO_USER:-' scripts/install-bridge.sh; then
  pass "the agent's owner comes from SUDO_USER when elevated"
else
  fail "the agent's owner is not resolved from SUDO_USER"
fi
# shellcheck disable=SC2016  # a literal pattern, not an expansion
if grep -q 'chown "\$FM_AGENT_USER" "\$AGENT_PLIST"' scripts/install-bridge.sh; then
  pass "a root-written plist is handed back to its owner"
else
  fail "a root-written plist stays root-owned in the user's LaunchAgents"
fi

echo "== a dry run writes nothing =="
rm -rf "${WORK:?}/home"
run_install "$WORK/tailnet.env" >/dev/null 2>&1
if [[ -z "$(find "$WORK/home" -name 'bridge.json5' -o -name '*.plist' 2>/dev/null)" ]]; then
  pass "--dry-run leaves no config and no agent behind"
else
  fail "--dry-run wrote files"
fi

echo "== a version probe that reads empty is diagnosed, not just reported =="
# shellcheck disable=SC2016
if grep -q 'for attempt in 1 2' lib.sh; then
  pass "the version probe is retried once"
else
  fail "a single transient probe still fails the whole install"
fi
if grep -q 'com.apple.quarantine' lib.sh; then
  pass "quarantine is named as a cause when it applies"
else
  fail "an empty version reading offers no cause"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "macos bridge install: all checks passed"
