#!/usr/bin/env bash
#
# install.sh — host-bootstrap front door for fm-comms.
#
# Places the Zenoh transport on this host for one role: the router (the office
# workstation), a bridge (a rig), or a client (a laptop with the CLI only). The
# per-role work lives in scripts/install-<role>.sh, each runnable standalone.
#
# Install (the URL is pinned to a release tag, never a moving branch):
#
#   curl -fsSL https://raw.githubusercontent.com/first-motive/fm-comms/v0.1.0/install.sh | bash -s -- --role router
#
# Inspect before running (always available):
#
#   curl -fsSL https://raw.githubusercontent.com/first-motive/fm-comms/v0.1.0/install.sh -o install.sh
#   less install.sh && bash install.sh --role router --dry-run
#
# Env overrides:
#   FM_COMMS_ROLE       role to install             (same as --role)
#   FM_COMMS_DIR        checkout dir for the pipe   (default: the identity card's
#                                                    workspace, else $HOME/.first-motive/fm-comms)
#   FM_INSTALL_DIR      where binaries go           (default: $HOME/.first-motive/bin)
#   FM_NO_MODIFY_PATH   skip shell-profile edits    (set to 1 in CI)
#   FM_SELFTEST         CI self-test, no real work  (set to 1 in CI)
#
# Passed down to the role script, which is expected to honour both:
#   FM_DRY_RUN          1 when --dry-run was given
#   FM_YES              1 when -y / --yes was given; prompt for nothing
#
# The body is wrapped in main() and called on the last line, so a truncated
# `curl | bash` leaves an incomplete function that never runs.

set -euo pipefail

FM_REPO="${FM_REPO:-first-motive/fm-comms}"
FM_TAG="${FM_TAG:-v0.1.0}"
FM_RAW_BASE="https://raw.githubusercontent.com/${FM_REPO}/${FM_TAG}"

FM_COMMS_ROLE="${FM_COMMS_ROLE:-}"
# Left empty deliberately: the default is the workspace this machine's identity
# card names, and the card cannot be read before lib.sh has loaded. Resolved in
# main() by fm_comms_dir_default.
FM_COMMS_DIR="${FM_COMMS_DIR:-}"
FM_INSTALL_DIR="${FM_INSTALL_DIR:-$HOME/.first-motive/bin}"
FM_NO_MODIFY_PATH="${FM_NO_MODIFY_PATH:-0}"
FM_SELFTEST="${FM_SELFTEST:-0}"
FM_YES="${FM_YES:-0}"

# Load lib.sh. From a clone it sits next to this script, so source it directly.
# Over a curl pipe there is no script on disk, so fetch it and eval — eval, not a
# process substitution `source`, because the pipe has already consumed stdin.
fm_load_lib() {
  local here lib
  if [ -n "${BASH_SOURCE[0]:-}" ] && here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" \
     && lib="$here/lib.sh" && [ -f "$lib" ]; then
    # shellcheck source=lib.sh disable=SC1091
    . "$lib"
  else
    # `eval "$(curl …)"` swallows a failed fetch: eval gets an empty string and
    # succeeds, and the first fm_* call then dies as "command not found". Capture
    # the body and check it, so a 404 or a dropped connection says so.
    local body
    if ! body="$(curl -fsSL "$FM_RAW_BASE/lib.sh")" || [ -z "$body" ]; then
      echo "install.sh: could not fetch lib.sh from $FM_RAW_BASE — check FM_TAG ($FM_TAG)." >&2
      return 1
    fi
    eval "$body"
  fi
}

# Echo where a curl-pipe install should put its checkout.
#
# A machine with an identity card already says where every First Motive checkout
# lives, so the pipe puts fm-comms there beside the rest rather than hiding it in
# a dotdir the operator has to be told about. A machine with no card — a laptop in
# client mode — keeps the dotdir, which needs no configuration to work.
fm_comms_dir_default() {
  local workspace
  if fm_machine_exists && workspace="$(fm_machine_get workspace 2>/dev/null)" && [ -n "$workspace" ]; then
    printf '%s\n' "$workspace/fm-comms"
  else
    printf '%s\n' "$HOME/.first-motive/fm-comms"
  fi
}

# The checkout this script belongs to, or empty when it arrived over a pipe.
fm_checkout() {
  local here
  [ -n "${BASH_SOURCE[0]:-}" ] || return 0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 0
  [ -d "$here/scripts" ] && printf '%s\n' "$here"
}

# Roles are whatever scripts/install-<role>.sh files the checkout carries, so a
# new role is one new script and nothing here changes.
fm_roles() {
  local checkout script role
  checkout="$(fm_checkout)" || return 0
  [ -n "$checkout" ] || return 0
  for script in "$checkout"/scripts/install-*.sh; do
    [ -f "$script" ] || continue
    role="${script##*/install-}"
    printf '%s\n' "${role%.sh}"
  done
}

usage() {
  cat <<'EOF'
install.sh — install the fm-comms Zenoh transport for one role

Usage: ./install.sh [install|uninstall] --role <role> [options]

  install      place the role's binaries, configs, and units (default)
  uninstall    remove what a previous install placed

Options:
  --role NAME  which role this host plays (router | bridge | client)
  -y, --yes    non-interactive; assume yes (CI mode)
  --dry-run    print what would happen, change nothing
  -h, --help   show this help

Env: FM_COMMS_ROLE, FM_COMMS_DIR, FM_INSTALL_DIR, FM_NO_MODIFY_PATH, FM_SELFTEST
     (see the header comment)
EOF
}

# Over the pipe there is no checkout, and the role scripts need this repo's
# configs beside them — so fetch the whole thing at the pinned tag and hand off
# to the clone's own install.sh.
bootstrap_checkout() {
  local dry="$1"
  if [ "$dry" = "1" ]; then
    fm_log "  would clone $FM_REPO@$FM_TAG into $FM_COMMS_DIR and re-run from there"
    return 0
  fi
  fm_require_cmd git
  if [ -d "$FM_COMMS_DIR/.git" ]; then
    fm_log "  updating $FM_COMMS_DIR to $FM_TAG"
    git -C "$FM_COMMS_DIR" fetch --depth 1 origin "refs/tags/$FM_TAG:refs/tags/$FM_TAG" --force
    git -C "$FM_COMMS_DIR" checkout --detach "refs/tags/$FM_TAG"
  else
    fm_log "  cloning $FM_REPO@$FM_TAG into $FM_COMMS_DIR"
    mkdir -p "$(dirname "$FM_COMMS_DIR")"
    git clone --depth 1 --branch "$FM_TAG" "https://github.com/${FM_REPO}.git" "$FM_COMMS_DIR"
  fi
}

# Hand off to the role's own script, which owns everything platform-specific.
run_role() {
  local action="$1" dry="$2" role="$3" checkout script
  checkout="$(fm_checkout)"
  script="$checkout/scripts/install-$role.sh"
  if [ ! -f "$script" ]; then
    fm_err "no installer for role '$role'"
    local known
    known="$(fm_roles | paste -sd' ' -)"
    if [ -n "$known" ]; then
      fm_err "  roles this checkout carries: $known"
    else
      fm_err "  this checkout carries no role installers yet"
    fi
    return 1
  fi
  FM_INSTALL_DIR="$FM_INSTALL_DIR" \
  FM_NO_MODIFY_PATH="$FM_NO_MODIFY_PATH" \
  FM_DRY_RUN="$dry" \
  FM_YES="$FM_YES" \
    bash "$script" "$action"
}

dispatch() {
  local action="$1" dry="$2" role="$3"

  if [ -z "$role" ]; then
    fm_err "no role given — pass --role <role> or set FM_COMMS_ROLE"
    usage
    return 1
  fi

  # The role becomes a path segment, so hold it to the shape a filename can take
  # — otherwise a stray value walks out of scripts/ and runs something else.
  if ! printf '%s' "$role" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
    fm_err "invalid role '$role' (want lowercase, digits, dashes)"
    return 1
  fi

  # From a pipe there is no checkout; get one, then re-run from it so the role
  # script sees the configs it needs.
  if [ -z "$(fm_checkout)" ]; then
    bootstrap_checkout "$dry"
    [ "$dry" = "1" ] && return 0
    FM_COMMS_ROLE="$role" exec bash "$FM_COMMS_DIR/install.sh" "$action" --role "$role"
  fi

  run_role "$action" "$dry" "$role"
}

# Prove the script survives the curl-pipe path — deps load, the OS resolves, the
# role list reads — before a user ever hits it. CI invokes this with FM_SELFTEST=1.
selftest() {
  local os arch roles
  os="$(fm_detect_os)"
  arch="$(fm_detect_arch)"
  roles="$(fm_roles | paste -sd' ' -)"
  fm_log "selftest ok: install.sh loaded lib (os=$os arch=$arch roles=${roles:-none})"
}

main() {
  fm_load_lib
  fm_banner

  [ -n "$FM_COMMS_DIR" ] || FM_COMMS_DIR="$(fm_comms_dir_default)"

  local cmd="install" dry=0 role="$FM_COMMS_ROLE"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install|uninstall) cmd="$1" ;;
      --role) shift; role="${1:-}" ;;
      --role=*) role="${1#--role=}" ;;
      -y|--yes) FM_YES=1 ;;
      --dry-run) dry=1 ;;
      -h|--help) usage; return 0 ;;
      *) fm_err "unknown argument: $1"; usage; return 1 ;;
    esac
    shift
  done

  if [ "$FM_SELFTEST" = "1" ]; then
    selftest
    return 0
  fi

  dispatch "$cmd" "$dry" "$role"
}

main "$@"
