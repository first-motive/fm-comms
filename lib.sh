#!/usr/bin/env bash
#
# lib.sh — shared bootstrap functions for a First Motive repo.
#
# SOURCED, never executed. The install.sh / run.sh front doors source this for
# OS and arch detection, logging, the brand banner, and checksum verification.
# Each scripts/<verb>.sh sources it too, so a verb runs standalone.
#
# Over a curl pipe there is no lib.sh on disk; the front door fetches this file
# and loads it with `eval`, so keep every definition self-contained and side
# effect free at load time. Do not set shell options here — the front door owns
# `set -euo pipefail`; a sourced file that flips shell options surprises callers.
#
# SECURITY: over the pipe this file is loaded with `eval`, so every function
# here is trusted code running in the caller's shell. Keep it minimal, keep it
# side-effect-free at load, and never put a secret in it. The eval load trusts
# the source repo and its TLS — pin the URL to a release tag and protect the
# repo's supply chain accordingly.

# Refuse direct execution: `return` succeeds only in a sourced context.
if ! (return 0 2>/dev/null); then
  echo "lib.sh is a function library; source it, do not execute it." >&2
  exit 1
fi

# Brand string used by the banner. Override per repo when copying this in.
FM_BRAND="${FM_BRAND:-First Motive}"

# Colour helpers, disabled when stdout is not a terminal so logs stay clean.
if [ -t 1 ]; then
  FM_C_RESET="$(printf '\033[0m')"
  FM_C_GREEN="$(printf '\033[32m')"
  FM_C_YELLOW="$(printf '\033[33m')"
  FM_C_RED="$(printf '\033[31m')"
else
  FM_C_RESET="" FM_C_GREEN="" FM_C_YELLOW="" FM_C_RED=""
fi

fm_log()  { printf '%s\n' "$*"; }
fm_ok()   { printf '%s%s%s\n' "$FM_C_GREEN" "$*" "$FM_C_RESET"; }
fm_warn() { printf '%s%s%s\n' "$FM_C_YELLOW" "$*" "$FM_C_RESET" >&2; }
fm_err()  { printf '%s%s%s\n' "$FM_C_RED" "$*" "$FM_C_RESET" >&2; }

# Print the brand banner. SHA-pin this string to fm-tools per repo so the brand
# stays identical across every front door rather than drifting copy by copy.
fm_banner() {
  printf '%s\n' "── ${FM_BRAND} ──"
}

# Echo the OS as linux | macos, or fail loudly on an unsupported platform.
fm_detect_os() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Linux)  printf 'linux\n' ;;
    Darwin) printf 'macos\n' ;;
    *) fm_err "unsupported OS: $uname_s"; return 1 ;;
  esac
}

# Echo the arch as x86_64 | aarch64, or fail loudly on an unsupported one.
fm_detect_arch() {
  local uname_m
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64)   printf 'x86_64\n' ;;
    arm64|aarch64)  printf 'aarch64\n' ;;
    *) fm_err "unsupported arch: $uname_m"; return 1 ;;
  esac
}

# Return success when a command is on PATH.
fm_has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Return success when Docker is installed and reachable.
fm_has_docker() { fm_has_cmd docker && docker info >/dev/null 2>&1; }

# Require a command or fail with a clear message.
fm_require_cmd() {
  fm_has_cmd "$1" || { fm_err "missing dependency: $1"; return 1; }
}

# Verify a file against an expected sha256 before it is executed. Picks whichever
# checksum tool the platform ships. A mismatch returns non-zero so the caller
# can abort before running a tampered or truncated download.
fm_verify_checksum() {
  local file="$1" expected="$2" actual
  [ -f "$file" ] || { fm_err "file not found: $file"; return 1; }
  if fm_has_cmd sha256sum; then
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
  elif fm_has_cmd shasum; then
    actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  else
    fm_err "no sha256 tool found (sha256sum or shasum)"
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    fm_err "checksum mismatch for $file"
    fm_err "  expected $expected"
    fm_err "  actual   $actual"
    return 1
  fi
}
