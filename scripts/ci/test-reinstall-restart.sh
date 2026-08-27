#!/usr/bin/env bash
#
# test-reinstall-restart.sh — a reinstall must change what the service runs.
#
# The bug this exists to keep dead: `install.sh --role bridge` rerendered
# /etc/fm-comms/bridge.json5 and reinstalled the unit, but `systemctl enable
# --now` does nothing at all to a unit that is already running. fm-ws-01 spent an
# hour filtering with the `processor` allow-list while its card and the file on
# disk both said `workstation` (fm-comms#20, 2026-08-27). Every artefact of the
# install was correct; the process was not.
#
# So the thing under test is not the render — check-transport.py grades that —
# it is the sentence "a reinstall with a changed profile changes what the service
# runs". The installer is driven in dry-run mode, where it prints the commands it
# would issue, and this asserts the restart is among them.
#
# Both service paths are covered on any host, because `uname` is stubbed: the
# choice between systemd and launchd is the one branch that cannot be exercised
# by running on one machine, and it is exactly where the macOS half of the bug
# would hide.
#
#   ./scripts/ci/test-reinstall-restart.sh
#
# No network, no privileges, no service manager — nothing here leaves the
# scratch directory.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$ROOT/lib.sh"

WORKDIR=""
FAILURES=0
cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Stubs for the commands the installer needs to exist but must never really run.
# `uname` is the load-bearing one: it decides which service path the installer
# takes, so overriding it is how one host tests both.
make_stubs() {
  local bin="$WORKDIR/bin"
  mkdir -p "$bin"

  cat >"$bin/uname" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "-s" ] && { printf '%s\n' "$FM_TEST_UNAME_S"; exit 0; }
exec /usr/bin/uname "$@"
STUB

  # Never invoked: every call the installer makes to these is wrapped in `run`,
  # which prints under FM_DRY_RUN. They exist only so fm_require_cmd is satisfied.
  local cmd
  for cmd in sudo gpg apt-get; do
    printf '#!/usr/bin/env bash\necho "STUB %s SHOULD NOT RUN: $*" >&2\nexit 1\n' \
      "$cmd" >"$bin/$cmd"
  done

  # The plist render asks where the bridge binary is, and takes the answer
  # literally. A stub that reports the pinned version also keeps the macOS
  # install step from trying to fetch one.
  cat >"$bin/zenoh-bridge-ros2dds" <<STUB
#!/usr/bin/env bash
printf 'zenoh-bridge-ros2dds $(fm_zenoh_version)\n'
STUB

  chmod +x "$bin"/*
  printf '%s\n' "$bin"
}

# A card for a machine whose workload this test changes underneath the installer.
write_fixtures() {
  cat >"$WORKDIR/machine.json" <<'JSON'
{
  "schema_version": 1,
  "name": "fm-ws-01",
  "role": "workstation",
  "fleet": "test",
  "transport": "zenoh",
  "workload": "processor",
  "workspace": "/home/fm/fm"
}
JSON

  cat >"$WORKDIR/fm-comms.env" <<'ENV'
FM_ROUTER_PORT=7447
FM_ROUTER_ENDPOINT=tcp/100.64.0.1:7447
FM_ROS_DOMAIN_ID=0
ENV
}

# Render one profile to a path, the same way an install would.
render_profile() {
  local profile="$1" dest="$2"
  FM_MACHINE_FILE="$WORKDIR/machine.json" \
  FM_COMMS_ENV_FILE="$WORKDIR/fm-comms.env" \
  FM_BRIDGE_PROFILE="$profile" \
    "$ROOT/run.sh" render bridge -o "$dest" >/dev/null
}

# Run the bridge installer against the scratch tree, for one OS and one profile.
run_installer() {
  local uname_s="$1" profile="$2"
  PATH="$WORKDIR/bin:$PATH" \
  FM_TEST_UNAME_S="$uname_s" \
  FM_DRY_RUN=1 \
  FM_YES=1 \
  FM_MACHINE_FILE="$WORKDIR/machine.json" \
  FM_COMMS_ENV_FILE="$WORKDIR/fm-comms.env" \
  FM_COMMS_CONF_DIR="$WORKDIR/etc" \
  FM_COMMS_USER_CONF_DIR="$WORKDIR/etc" \
  FM_COMMS_USER_LOG_DIR="$WORKDIR/log" \
  FM_BRIDGE_PROFILE="$profile" \
    "$ROOT/scripts/install-bridge.sh" install 2>&1
}

check() {
  local what="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    fm_ok "  ok   $what"
  else
    fm_err "  FAIL $what"
    fm_err "       expected to find: $needle"
    FAILURES=$((FAILURES + 1))
  fi
}

main() {
  WORKDIR="$(mktemp -d)"
  mkdir -p "$WORKDIR/etc"
  write_fixtures
  make_stubs >/dev/null

  fm_log "Reinstall restart (zenoh $(fm_zenoh_version))"

  # The premise: the two profiles are not the same file. Without this the
  # restart assertions below would pass on a change that changed nothing.
  render_profile processor "$WORKDIR/processor.json5"
  render_profile workstation "$WORKDIR/workstation.json5"
  if fm_file_differs "$WORKDIR/workstation.json5" "$WORKDIR/processor.json5"; then
    fm_ok "  ok   the workstation profile renders differently from the processor one"
  else
    fm_err "  FAIL the two profiles render the same file — the rest proves nothing"
    return 1
  fi

  local out
  # An installed bridge running the processor allow-list, as fm-ws-01 was.
  cp "$WORKDIR/processor.json5" "$WORKDIR/etc/bridge.json5"

  out="$(run_installer Linux workstation)"
  check "linux: a changed profile restarts the unit" "$out" \
    "config changed — restarting fm-zenoh-bridge.service"
  check "linux: the restart is a real systemctl call" "$out" \
    "would run: sudo systemctl restart fm-zenoh-bridge.service"

  out="$(run_installer Darwin workstation)"
  check "macos: a changed profile kickstarts the agent" "$out" \
    "config changed — kickstarting ai.firstmotive.zenoh-bridge"
  check "macos: the kickstart replaces the running process" "$out" \
    "would run: launchctl kickstart -k gui/$(id -u)/ai.firstmotive.zenoh-bridge"

  # The other half: a reinstall that changes nothing says so, and still leaves
  # the running process matching the file on disk.
  cp "$WORKDIR/workstation.json5" "$WORKDIR/etc/bridge.json5"

  out="$(run_installer Linux workstation)"
  check "linux: an unchanged profile try-restarts instead" "$out" \
    "config unchanged — try-restart fm-zenoh-bridge.service"

  out="$(run_installer Darwin workstation)"
  check "macos: an unchanged profile still kickstarts" "$out" \
    "config unchanged — kickstarting ai.firstmotive.zenoh-bridge"

  if [ "$FAILURES" -gt 0 ]; then
    fm_err "$FAILURES check(s) failed — a reinstall would leave the old config running"
    return 1
  fi
  fm_ok "reinstall restart: all checks passed"
}

main "$@"
