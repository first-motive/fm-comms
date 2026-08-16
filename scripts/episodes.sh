#!/usr/bin/env bash
#
# episodes.sh — the episode queryable on a processor rig.
#
# Serves the recorder's episode index and MCAP fetch over Zenoh, so the desktop
# and a remote contractor can pull one episode on demand instead of waiting for a
# whole recordings directory to sync. Reads only: the rsync pipeline stays the
# source of truth for moving recordings between hosts.
#
#     ./run.sh episodes run          serve in the foreground (Ctrl-C to stop)
#     ./run.sh episodes install      install + enable the systemd unit
#     ./run.sh episodes uninstall    remove the unit
#
# The recordings directory is a per-host fact and is derived, not typed: it is
# `recordings` under the workspace this machine's identity card names. Setting
# FM_EPISODES_DIR in /etc/fm-comms.env overrides that for a rig whose bags live
# somewhere unusual. FM_EPISODES_MAX_BYTES — the ceiling above which an MCAP is
# refused rather than returned in one reply — is fleet-wide and stays in the env
# file.
#
# Read the unit before installing it:
#     ./run.sh render episodes
#
# Python lives in episodes/ as its own uv project — it runs beside the bags, not
# inside the ROS env, and there is no zenoh package for pixi or rosdep to supply.

set -euo pipefail

FM_DRY_RUN="${FM_DRY_RUN:-0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh disable=SC1091
. "$ROOT/lib.sh"

# lib.sh owns the path so the installers, the render verb, and this verb cannot
# disagree about which file the fleet-wide values live in.
ENV_FILE="$FM_COMMS_ENV_FILE"
UNIT=fm-comms-episodes.service

run() {
  if [ "$FM_DRY_RUN" = "1" ]; then
    fm_log "  would run: $*"
    return 0
  fi
  "$@"
}

do_run() {
  fm_require_cmd uv
  # uv resolves and syncs the project on demand, so a first run on a fresh rig
  # needs no separate install step. Resolving first means the foreground run and
  # the unit read the same recordings directory rather than the service's Python
  # falling back to a home-relative guess.
  fm_comms_resolve
  export FM_EPISODES_DIR
  cd "$ROOT/episodes"
  exec uv run episodes
}

do_install() {
  local os
  os="$(fm_detect_os)"
  if [ "$os" != linux ]; then
    fm_err "the unit is Linux-only; run it in the foreground with: ./run.sh episodes run"
    return 1
  fi
  fm_require_cmd uv

  if [ ! -f "$ENV_FILE" ]; then
    fm_err "$ENV_FILE is missing — install a role first (./install.sh --role bridge)"
    return 1
  fi

  # Build the venv now rather than at boot: the unit runs its console script
  # directly, so starting the service never depends on the network.
  fm_log "  syncing the episodes project"
  run uv sync --project "$ROOT/episodes" --quiet

  fm_log "  rendering $UNIT"
  if [ "$FM_DRY_RUN" = "1" ]; then
    # Print the unit rather than describing it: the values that go wrong here are
    # the account and the recordings path, and both are legible in the text.
    fm_log "  would write /etc/systemd/system/$UNIT:"
    fm_comms_render episodes -
  else
    local tmp
    tmp="$(mktemp)"
    fm_comms_render episodes "$tmp"
    sudo install -m 0644 "$tmp" "/etc/systemd/system/$UNIT"
    rm -f "$tmp"
  fi
  run sudo systemctl daemon-reload
  run sudo systemctl enable --now "$UNIT"
  fm_log "  watch it with: journalctl -u $UNIT -f"
  fm_ok "episodes install complete."
}

do_uninstall() {
  fm_log "Removing the episode queryable"
  run sudo systemctl disable --now "$UNIT" || true
  run sudo rm -f "/etc/systemd/system/$UNIT"
  run sudo systemctl daemon-reload
  fm_log "  left in place: $ENV_FILE and the recordings themselves"
  fm_ok "episodes uninstall complete."
}

main() {
  case "${1:-run}" in
    run)       do_run ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *) fm_err "usage: $0 [run|install|uninstall]"; return 1 ;;
  esac
}

main "$@"
