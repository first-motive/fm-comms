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
# The same sentence holds for a workstation's second bridge, the Jazzy one its
# sim runs need (`./install.sh --role bridge-sim`): it is the same installer
# under another unit name, so it is driven through its own front door and held
# to the same restart, plus the one thing that makes it a second bridge rather
# than a copy of the first — it never touches fm-zenoh-bridge.service.
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
  local uname_s="$1" profile="$2" action="${3:-install}"
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
    "$ROOT/scripts/install-bridge.sh" "$action" 2>&1
}

# Run the sim bridge's installer the same way, through its own script. Never
# fails the test by itself: a refusal is one of the things graded.
run_sim_installer() {
  local uname_s="$1" action="$2" profile="$3"
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
    "$ROOT/scripts/install-bridge-sim.sh" "$action" 2>&1 || true
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

check_absent() {
  local what="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    fm_err "  FAIL $what"
    fm_err "       expected NOT to find: $needle"
    FAILURES=$((FAILURES + 1))
  else
    fm_ok "  ok   $what"
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

  # The sim bridge, first install: nothing at bridge-sim.json5 yet, so the
  # render is a change and its own unit restarts — on jazzy, on its own config,
  # under its own node name, and with the workstation's bridge left alone.
  out="$(run_sim_installer Linux install workstation)"
  check "sim: a new config restarts its own unit" "$out" \
    "config changed — restarting fm-zenoh-bridge-sim.service"
  check "sim: the restart is a real systemctl call" "$out" \
    "would run: sudo systemctl restart fm-zenoh-bridge-sim.service"
  check "sim: the unit runs jazzy" "$out" "Environment=ROS_DISTRO=jazzy"
  check "sim: the unit reads its own config" "$out" \
    "--config /etc/fm-comms/bridge-sim.json5"
  check "sim: the unit keeps the workstation's loopback DDS" "$out" \
    "Environment=ROS_LOCALHOST_ONLY=1"
  check "sim: the config takes the workstation's namespace" "$out" \
    'namespace: "/fm_ws_01"'
  check "sim: the config takes a node name of its own" "$out" \
    'nodename: "zenoh_bridge_fm_ws_01_sim"'
  check_absent "sim: the workstation's bridge is not restarted" "$out" \
    "systemctl restart fm-zenoh-bridge.service"

  # A reinstall that changes nothing says so, like the main bridge's.
  FM_MACHINE_FILE="$WORKDIR/machine.json" FM_COMMS_ENV_FILE="$WORKDIR/fm-comms.env" \
    "$ROOT/run.sh" render bridge-sim -o "$WORKDIR/etc/bridge-sim.json5" >/dev/null
  out="$(run_sim_installer Linux install workstation)"
  check "sim: an unchanged config try-restarts instead" "$out" \
    "config unchanged — try-restart fm-zenoh-bridge-sim.service"

  # On a Mac the sim bridge runs in fm-sim's container beside each run, so the
  # installer renders its config and the Cyclone profile and installs no agent.
  rm -f "$WORKDIR/etc/bridge-sim.json5"
  out="$(run_sim_installer Darwin install workstation)"
  check "sim on macOS: the config is rendered to the user config dir" "$out" \
    "would write $WORKDIR/etc/bridge-sim.json5"
  check "sim on macOS: the config takes a node name of its own" "$out" \
    'nodename: "zenoh_bridge_fm_ws_01_sim"'
  check "sim on macOS: the Cyclone profile is placed beside it" "$out" \
    "would write $WORKDIR/etc/cyclonedds.xml"
  check "sim on macOS: the log names who runs the bridge" "$out" \
    "fm-sim's agent runs this bridge beside each run"
  check_absent "sim on macOS: no LaunchAgent is touched" "$out" "launchctl"
  check_absent "sim on macOS: no LaunchAgent is written" "$out" "Library/LaunchAgents/"

  # The Cyclone profile is shared by the Mac's two bridge configs, so each
  # uninstall removes it only when the other config is gone.
  : >"$WORKDIR/etc/bridge.json5"
  out="$(run_sim_installer Darwin uninstall workstation)"
  check "sim on macOS: uninstall removes the rendered config" "$out" \
    "would run: rm -f $WORKDIR/etc/bridge-sim.json5"
  check "sim on macOS: uninstall says the main bridge keeps the Cyclone profile" "$out" \
    "cyclonedds.xml, which the Mac's own bridge uses"
  check_absent "sim on macOS: uninstall leaves the Cyclone profile" "$out" \
    "rm -f $WORKDIR/etc/cyclonedds.xml"
  check_absent "sim on macOS: uninstall leaves the Mac's own bridge" "$out" "launchctl"
  check_absent "sim on macOS: uninstall leaves the Mac's own LaunchAgent" "$out" \
    "Library/LaunchAgents/"
  rm -f "$WORKDIR/etc/bridge.json5"
  out="$(run_sim_installer Darwin uninstall workstation)"
  check "sim on macOS: uninstall alone removes the Cyclone profile" "$out" \
    "would run: rm -f $WORKDIR/etc/cyclonedds.xml"

  : >"$WORKDIR/etc/bridge-sim.json5"
  out="$(run_installer Darwin cockpit uninstall)"
  check "macos: uninstall keeps the Cyclone profile the sim config reads" "$out" \
    "left in place: $WORKDIR/etc/cyclonedds.xml, which the sim bridge config uses"
  check_absent "macos: uninstall does not remove the shared Cyclone profile" "$out" \
    "rm -f $WORKDIR/etc/cyclonedds.xml"
  rm -f "$WORKDIR/etc/bridge-sim.json5"
  out="$(run_installer Darwin cockpit uninstall)"
  check "macos: uninstall alone removes the Cyclone profile" "$out" \
    "would run: rm -f $WORKDIR/etc/cyclonedds.xml"

  # Where a second bridge would be a mistake, it is refused before anything is
  # placed: a sim host's own bridge is this profile.
  out="$(run_sim_installer Linux install sim)"
  check "sim: refused on a sim host" "$out" "its own bridge already carries the sim profile"
  check_absent "sim: nothing is installed on a sim host" "$out" "would run:"

  # Uninstall removes the sim bridge's unit and config and nothing of the
  # workstation's.
  out="$(run_sim_installer Linux uninstall workstation)"
  check "sim: uninstall disables its own unit" "$out" \
    "would run: sudo systemctl disable --now fm-zenoh-bridge-sim.service"
  check "sim: uninstall removes its own config" "$out" \
    "would run: sudo rm -f $WORKDIR/etc/bridge-sim.json5"
  check_absent "sim: uninstall leaves the workstation's unit running" "$out" \
    "disable --now fm-zenoh-bridge.service"
  check_absent "sim: uninstall leaves the workstation's unit file" "$out" \
    "rm -f /etc/systemd/system/fm-zenoh-bridge.service"
  check_absent "sim: uninstall leaves the workstation's config" "$out" \
    "$WORKDIR/etc/bridge.json5"

  if [ "$FAILURES" -gt 0 ]; then
    fm_err "$FAILURES check(s) failed — a reinstall would leave the old config running"
    return 1
  fi
  fm_ok "reinstall restart: all checks passed"
}

main "$@"
