#!/usr/bin/env bash
#
# compose.sh — drive the Zenoh transport as containers.
#
# deploy/compose.zenoh.yaml takes the image tag from FM_ZENOH_VERSION, and
# compose interpolates that at parse time from the shell environment — an
# env_file cannot supply it. This verb exports the pinned value from
# zenoh/zenoh.version and then hands every argument to docker compose, so the
# container path and the systemd path resolve the same version from the same file.
#
#     ./run.sh compose up -d zenoh-bridge
#     ./run.sh compose logs -f zenoh-bridge
#     ./run.sh compose down
#
# Overlays onto the workspace compose file when one is present beside this
# checkout (fm-comms is vendored into fm-ros2 at comms/), and stands alone
# otherwise.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh disable=SC1091
. "$ROOT/lib.sh"

main() {
  fm_require_cmd docker

  FM_ZENOH_VERSION="$(fm_zenoh_version)"
  export FM_ZENOH_VERSION

  local files=()
  # The workspace's own compose file, when this checkout sits inside one. The
  # base file defines the stack; this overlay only adds the two Zenoh services.
  local workspace="$ROOT/../docker/compose.yaml"
  [ -f "$workspace" ] && files+=(-f "$workspace")
  files+=(-f "$ROOT/deploy/compose.zenoh.yaml")

  fm_log "zenoh $FM_ZENOH_VERSION"
  docker compose "${files[@]}" "$@"
}

main "$@"
