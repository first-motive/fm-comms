#!/usr/bin/env bash
#
# run.sh — launch front door for fm-comms.
#
# A thin, branded dispatcher: source lib.sh, then hand off to a modular
# scripts/<verb>.sh. Every verb is runnable standalone, so a developer can call
# one step without going through here.
#
# Usage:
#   ./run.sh <verb> [args…]
#   ./run.sh --help
#
# Over a curl pipe stdin is consumed, so an interactive verb reattaches the
# terminal via /dev/tty (see reattach_tty). The body is wrapped in main() and
# called on the last line, so a truncated pipe never half-runs.

set -euo pipefail

FM_REPO="${FM_REPO:-first-motive/fm-comms}"
FM_TAG="${FM_TAG:-v0.2.0-zenoh.3}"
FM_RAW_BASE="https://raw.githubusercontent.com/${FM_REPO}/${FM_TAG}"

FM_SELFTEST="${FM_SELFTEST:-0}"

# Resolve the script's own directory, following symlinks, so scripts/<verb>.sh
# is found regardless of the caller's working directory.
fm_script_dir() {
  local source="${BASH_SOURCE[0]:-}" dir
  [ -n "$source" ] || { pwd; return; }
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    case "$source" in /*) ;; *) source="$dir/$source" ;; esac
  done
  cd -P "$(dirname "$source")" && pwd
}

fm_load_lib() {
  local here lib
  if here="$(fm_script_dir)" && lib="$here/lib.sh" && [ -f "$lib" ]; then
    # shellcheck source=lib.sh disable=SC1091
    . "$lib"
  else
    # `eval "$(curl …)"` swallows a failed fetch: eval gets an empty string and
    # succeeds, and the first fm_* call then dies as "command not found". Capture
    # the body and check it, so a 404 or a dropped connection says so.
    local body
    if ! body="$(curl -fsSL "$FM_RAW_BASE/lib.sh")" || [ -z "$body" ]; then
      echo "run.sh: could not fetch lib.sh from $FM_RAW_BASE — check FM_TAG ($FM_TAG)." >&2
      return 1
    fi
    eval "$body"
  fi
}

# Reattach an interactive terminal after a curl pipe has consumed stdin. A verb
# that prompts needs this.
#
# Three guards, each earning its place: stdin may already be a terminal (nothing
# to do); /dev/tty may not exist; and — the one that bites — /dev/tty can exist
# yet be unopenable in a session with no controlling terminal, which is every CI
# job and every systemd unit. An `exec` redirection that fails takes a
# non-interactive shell down with it, so the open is rehearsed in a subshell first.
reattach_tty() {
  [ -t 0 ] && return 0
  [ -e /dev/tty ] || return 0
  ( : </dev/tty ) 2>/dev/null || return 0
  exec </dev/tty
}

# The verbs this checkout carries, excluding the install-<role>.sh scripts —
# those are install.sh's business, not launch verbs.
fm_verbs() {
  local here script verb
  here="$(fm_script_dir)"
  for script in "$here"/scripts/*.sh; do
    [ -f "$script" ] || continue
    verb="$(basename "$script" .sh)"
    case "$verb" in install-*) continue ;; esac
    printf '%s\n' "$verb"
  done
}

usage() {
  cat <<'EOF'
run.sh — launch an fm-comms verb

Usage: ./run.sh <verb> [args…]
       ./run.sh --help

Verbs live in scripts/<verb>.sh and are runnable standalone.

  -h, --help   show this help
EOF
  local verbs
  verbs="$(fm_verbs | paste -sd' ' -)"
  [ -n "$verbs" ] && printf '\nVerbs here: %s\n' "$verbs"
}

main() {
  fm_load_lib
  fm_banner

  if [ "$FM_SELFTEST" = "1" ]; then
    fm_log "selftest ok: run.sh loaded lib (verbs=$(fm_verbs | paste -sd' ' -))"
    return 0
  fi

  if [ "$#" -eq 0 ]; then
    usage
    return 1
  fi

  case "$1" in
    -h|--help) usage; return 0 ;;
  esac

  local verb="$1"; shift

  # The verb becomes a path segment, so hold it to the shape a filename can take
  # — otherwise a stray value walks out of scripts/ and runs something else.
  if ! printf '%s' "$verb" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
    fm_err "invalid verb: $verb"
    usage
    return 1
  fi

  local here script
  here="$(fm_script_dir)"
  script="$here/scripts/$verb.sh"

  if [ ! -f "$script" ]; then
    fm_err "unknown verb: $verb"
    usage
    return 1
  fi

  reattach_tty
  bash "$script" "$@"
}

main "$@"
