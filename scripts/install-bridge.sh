#!/usr/bin/env bash
#
# install-bridge.sh — stand this machine up with a Zenoh ROS 2 bridge.
#
# The bridge joins the machine's local DDS graph and republishes the allowed
# topics onto Zenoh under its namespace. That namespace is derived from the
# machine's identity card and typed nowhere: fm-rec-01 becomes fm_rec_01. Which
# topics cross depends on what work the machine does, which the card's `workload`
# names: it selects zenoh/bridge-<profile>.json5 (recorder | processor | robot |
# workstation | cockpit).
#
# Two service paths, chosen by OS, because the two machines are not alike:
#
#   linux   a rig    systemd unit, system-wide, up at boot
#   macos   a Mac    launchd LaunchAgent, per user, up while someone is logged in
#
# The Mac needs a bridge for the same reason a rig does. Under the zenoh profile
# its DDS graph is loopback-only, so without one its ROS tools see nothing the
# fleet publishes — which is why the `cockpit` profile exists and why the gate's
# "the Mac sees /joint_states" lines can pass at all (fm-comms#19).
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
# lib.sh owns both config dirs for the same reason it owns the env path: the
# render verb prints the plist that names them, and a second copy here would let
# the printed text and the installed file disagree.
CONF_DIR="$FM_COMMS_CONF_DIR"
USER_CONF_DIR="$FM_COMMS_USER_CONF_DIR"
LOG_DIR="$FM_COMMS_USER_LOG_DIR"
UNIT=fm-zenoh-bridge.service
AGENT_PLIST="$HOME/Library/LaunchAgents/$FM_LAUNCHD_BRIDGE_LABEL.plist"

# Set by render_config: 1 when the config just rendered differs from the one
# already installed. The service step reads it to choose how loudly to restart.
FM_RENDER_CHANGED=0

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
  # --allow-downgrades: a pin means THIS version, whatever is there now — a host
  # that drifted up (fm-rec-01 reached 1.10.0 under an active hold) must come
  # back without a human untangling apt.
  # --allow-change-held-packages: the hold below is this installer's own; apt
  # must be allowed to move THROUGH it when the pin itself changes.
  run sudo apt-get install -y --allow-downgrades --allow-change-held-packages \
    "zenoh-bridge-ros2dds=$version"
  # The pin above only chooses what to install; a later `apt upgrade` — fm-setup's
  # own system-update step included — would move it to whatever the Eclipse repo
  # serves next (1.10.0 landed on fm-ws-01 that way, #21). Hold it so the version
  # changes only when zenoh/zenoh.version does.
  run sudo apt-mark hold zenoh-bridge-ros2dds
}

install_macos() {
  # There is no apt on a Mac and no per-version brew formula, so the binary comes
  # from Eclipse's standalone build of exactly the pinned version — the same
  # mechanism, and the same ~/.local/bin, that the router's zenohd takes.
  fm_install_zenoh_bridge_macos "$1"
}

# Place the fleet-wide env file, then stop only if a value this role needs is
# still missing. The file being new is not itself a reason to stop: the example
# carries every fleet-wide default, and the one value a bridge cannot derive is
# the router's endpoint.
place_env() {
  if [ -f "$ENV_FILE" ]; then
    fm_log "  $ENV_FILE exists; leaving it alone"
  else
    fm_log "  placing $ENV_FILE from the example"
    run sudo install -m 0644 "$ROOT/systemd/fm-comms.env.example" "$ENV_FILE"
  fi
  [ "$FM_DRY_RUN" = "1" ] && return 0
  local missing
  missing="$(fm_comms_env_unfilled FM_ROUTER_ENDPOINT)"
  [ -z "$missing" ] && return 0
  fm_warn "  fill in $ENV_FILE ($missing), then re-run"
  fm_warn "  this machine's namespace is not in there — it comes from $(fm_machine_file)"
  return 1
}

# Render the config to DEST, printing it instead when this is a dry run.
#
# Printed rather than described: a dry run whose only output is "would render X"
# cannot catch the mistake the render itself would make — an empty namespace or
# an endpoint nobody filled in are both visible in the text and invisible in the
# summary.
render_config() {
  local dest="$1" tmp
  tmp="$(mktemp)"
  fm_comms_render bridge "$tmp" || { rm -f "$tmp"; return 1; }
  # Compared before the dry run returns, not after: "would this reinstall change
  # what the service is running" is the question a dry run is asked, and it can
  # be answered without writing anything.
  if fm_file_differs "$tmp" "$dest"; then FM_RENDER_CHANGED=1; else FM_RENDER_CHANGED=0; fi
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would write $dest:"
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  case "$dest" in
    "$CONF_DIR"/*) sudo install -m 0644 "$tmp" "$dest" ;;
    *) install -m 0644 "$tmp" "$dest" ;;
  esac
  rm -f "$tmp"
}

# The Linux service path: a systemd unit, system-wide, enabled and started.
install_unit_linux() {
  fm_log "  rendering $CONF_DIR/bridge.json5"
  run sudo mkdir -p "$CONF_DIR"
  render_config "$CONF_DIR/bridge.json5" || return 1

  # The same Cyclone profile the macOS agent gets (#23): without it the bridge
  # runs stock discovery — default interface, ~9-participant loopback ceiling —
  # and quietly misses nodes past the ceiling; fm-rec-01's cameras never
  # crossed while every gate line around them stayed green.
  fm_log "  installing $CONF_DIR/cyclonedds.xml"
  run sudo install -m 0644 "$ROOT/zenoh/bridge-cyclonedds.xml" "$CONF_DIR/cyclonedds.xml"

  fm_log "  installing $UNIT"
  run sudo install -m 0644 "$ROOT/systemd/$UNIT" "/etc/systemd/system/$UNIT"
  run sudo systemctl daemon-reload
  run sudo systemctl enable --now "$UNIT"

  # `enable --now` starts a stopped unit and does nothing whatever to a running
  # one, so a reinstall that rerendered the config left the old process holding
  # the old allow-list: fm-ws-01 filtered with the `processor` profile for an
  # hour after its card and the file on disk both said `workstation`
  # (fm-comms#20, 2026-08-27). The restart below is what makes the installed
  # config and the running process the same thing.
  #
  # `restart` when the render changed, `try-restart` when it did not. Both end
  # with the service running the file on disk; the split is for the log, so the
  # line an operator reads says which of the two reinstalls this was.
  if [ "$FM_RENDER_CHANGED" = "1" ]; then
    fm_log "  config changed — restarting $UNIT"
    run sudo systemctl restart "$UNIT"
  else
    fm_log "  config unchanged — try-restart $UNIT"
    run sudo systemctl try-restart "$UNIT"
  fi
  fm_log "  watch it with: journalctl -u $UNIT -f"
}

# Who the LaunchAgent belongs to, and how to talk to launchd about it.
#
# The bridge is a per-user agent: its plist lives in the user's ~/Library and its
# domain is `gui/<their uid>`. Run the installer under sudo — which the Linux path
# needs, and which an operator therefore reaches for on both — and `id -u` is 0,
# so every launchctl call addresses `gui/0`. launchd refuses that domain outright:
#
#   Bootstrap failed: 125: Domain does not support specified action
#
# The install then leaves a rendered config that nothing has loaded, which reads
# as success right up until the bridge is found running its previous endpoint.
#
# So the agent's owner is resolved once — SUDO_USER when the installer was
# elevated, this user otherwise — and every launchctl call is made as them.
FM_AGENT_USER="${SUDO_USER:-$(id -un)}"
FM_AGENT_UID="$(id -u "$FM_AGENT_USER" 2>/dev/null || id -u)"

# Run one launchctl command in the agent owner's context.
fm_launchctl() {
  if [ "$(id -u)" = 0 ] && [ "$FM_AGENT_USER" != root ]; then
    run sudo -u "$FM_AGENT_USER" launchctl "$@"
  else
    run launchctl "$@"
  fi
}

# The macOS service path: a user LaunchAgent, rendered and bootstrapped.
#
# Nothing here needs sudo, and that is the point — the config and the job belong
# to the account whose ROS tools they serve. `launchctl bootstrap gui/<uid>`
# rather than the deprecated `load`: bootstrap reports why a job was refused,
# where `load` exits 0 on a plist launchd then ignores, which is a bridge that
# looks installed and is not running.
install_agent_macos() {
  fm_log "  rendering $USER_CONF_DIR/bridge.json5"
  run mkdir -p "$USER_CONF_DIR" "$LOG_DIR" "$(dirname "$AGENT_PLIST")"
  render_config "$USER_CONF_DIR/bridge.json5" || return 1

  # The DDS side, which launchd cannot inherit from a shell. Static, so it is
  # copied rather than rendered.
  fm_log "  installing $USER_CONF_DIR/cyclonedds.xml"
  run install -m 0644 "$ROOT/zenoh/bridge-cyclonedds.xml" "$USER_CONF_DIR/cyclonedds.xml"

  # macOS Local Network privacy, which no error message will mention.
  #
  # A LaunchAgent has no Local Network permission of its own, and macOS refuses
  # its connections to private LAN addresses with EHOSTUNREACH — while the same
  # address answers `nc` from Terminal, which does hold the permission. The bridge
  # then dies at start with
  #
  #   No route to host (os error 65) ... Failed to start Zenoh runtime
  #
  # and every reading looks like a network fault. A Tailscale address is not
  # "local network" and is unaffected, which is why the Mac's endpoint is the
  # tailnet one even in the office (fm-comms#18, measured 2026-08-31).
  case "${FM_ROUTER_ENDPOINT:-}" in
    *tcp/10.*|*tcp/192.168.*|*tcp/172.1[6-9].*|*tcp/172.2[0-9].*|*tcp/172.3[01].*)
      fm_warn "  FM_ROUTER_ENDPOINT is a private LAN address: ${FM_ROUTER_ENDPOINT}"
      fm_warn "  macOS blocks a LaunchAgent from reaching one (Local Network privacy),"
      fm_warn "  so this bridge will fail to start with 'No route to host'."
      fm_warn "  Use the router's tailnet address here; the rigs can keep the LAN one."
      ;;
  esac

  fm_log "  installing $AGENT_PLIST"
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would write $AGENT_PLIST"
  else
    fm_comms_render launchagent "$AGENT_PLIST" || return 1
  fi

  # An existing job holds the DDS participant and the router session, so it is
  # taken out first. It may legitimately not be loaded, which is not a failure
  # worth stopping the install for.
  # Everything past the render mutates this machine: it installs an agent into the
  # user's LaunchAgents and restarts the running bridge. FM_DRY_RUN promises none
  # of that happens, and only the render honoured it — so a dry run rewrote a live
  # config and kickstarted the bridge onto it (found 2026-08-31, twice, on the Mac
  # whose fleet visibility it removed). Stop here instead.
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would install $AGENT_PLIST"
    fm_log "  would (re)load $FM_LAUNCHD_BRIDGE_LABEL in gui/$FM_AGENT_UID"
    return 0
  fi

  # Written by root when the installer was elevated, and launchd will not load an
  # agent out of a user's LaunchAgents that the user does not own. Hand it back
  # along with the rendered config and the log directory beside it.
  if [ "$(id -u)" = 0 ] && [ "$FM_AGENT_USER" != root ]; then
    run chown "$FM_AGENT_USER" "$AGENT_PLIST" 2>/dev/null || true
    run chown -R "$FM_AGENT_USER" "$FM_COMMS_USER_CONF_DIR" "$LOG_DIR" 2>/dev/null || true
  fi

  fm_launchctl bootout "gui/$FM_AGENT_UID/$FM_LAUNCHD_BRIDGE_LABEL" 2>/dev/null || true
  fm_launchctl bootstrap "gui/$FM_AGENT_UID" "$AGENT_PLIST"

  # The macOS half of the same guarantee. bootout/bootstrap already replaces the
  # process in the ordinary case, but a bootout that was refused leaves bootstrap
  # a no-op on an already-loaded job, and the survivor would still be running the
  # previous config. `kickstart -k` kills and respawns whatever is loaded, so the
  # process after this line is the one that read the config just rendered.
  if [ "$FM_RENDER_CHANGED" = "1" ]; then
    fm_log "  config changed — kickstarting $FM_LAUNCHD_BRIDGE_LABEL"
  else
    fm_log "  config unchanged — kickstarting $FM_LAUNCHD_BRIDGE_LABEL to match the file on disk"
  fi
  fm_launchctl kickstart -k "gui/$FM_AGENT_UID/$FM_LAUNCHD_BRIDGE_LABEL"
  fm_log "  watch it with: tail -f $LOG_DIR/zenoh-bridge.log"
}

do_install() {
  local os version
  os="$(fm_detect_os)"
  version="$(fm_zenoh_version)"

  # The card decides whether this machine belongs on the Zenoh fabric at all. One
  # still on dds-lan gets a clear refusal here rather than a second, contradictory
  # transport running beside the one it already speaks.
  fm_comms_require_transport || return 1

  fm_log "Installing the Zenoh ROS 2 bridge (zenoh $version) on $os"

  case "$os" in
    linux) install_linux "$version" ;;
    macos) install_macos "$version" ;;
  esac

  place_env || return 0

  case "$os" in
    linux) install_unit_linux ;;
    macos) install_agent_macos ;;
  esac

  fm_ok "bridge install complete."
}

do_uninstall() {
  local os
  os="$(fm_detect_os)"
  fm_log "Removing the Zenoh ROS 2 bridge"
  if [ "$os" = linux ]; then
    run sudo systemctl disable --now "$UNIT" || true
    run sudo rm -f "/etc/systemd/system/$UNIT"
    run sudo systemctl daemon-reload
    # Only what this script placed. $ENV_FILE holds the operator's own values, so
    # it survives an uninstall and a later reinstall picks it back up.
    run sudo rm -f "$CONF_DIR/bridge.json5"
    # The package stays, but not pinned: once fm-comms no longer manages it,
    # apt may move it freely.
    run sudo apt-mark unhold zenoh-bridge-ros2dds 2>/dev/null || true
    fm_log "  left in place: $ENV_FILE and the zenoh-bridge-ros2dds package (unheld)"
  else
    fm_launchctl bootout "gui/$FM_AGENT_UID/$FM_LAUNCHD_BRIDGE_LABEL" 2>/dev/null || true
    run rm -f "$AGENT_PLIST" "$USER_CONF_DIR/bridge.json5" "$USER_CONF_DIR/cyclonedds.xml"
    # The logs outlive the job on purpose: the reason a bridge was removed is
    # usually in them, and this is the moment someone wants to read it.
    fm_log "  left in place: $ENV_FILE, $LOG_DIR, and the zenoh-bridge-ros2dds binary"
  fi
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
