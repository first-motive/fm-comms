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

# --- fm-comms specifics ------------------------------------------------------

# Echo this checkout's root, from wherever the sourcing script lives.
fm_comms_root() {
  local lib="${BASH_SOURCE[0]}"
  cd "$(dirname "$lib")" && pwd
}

# Echo the pinned Zenoh version. zenoh/zenoh.version is the single source; every
# install path reads it here so a router and a bridge cannot land on different
# releases.
fm_zenoh_version() {
  local file
  file="$(fm_comms_root)/zenoh/zenoh.version"
  [ -f "$file" ] || { fm_err "missing $file"; return 1; }
  sed -n 's/^FM_ZENOH_VERSION=\(.*\)$/\1/p' "$file" | head -1
}

# Fingerprint of the key Eclipse signs the Zenoh debian repo with, taken from the
# signature on https://download.eclipse.org/zenoh/debian-repo/Release. Pinned here
# so a swapped key is caught: fetching a key over TLS only proves who served it,
# not that it is the key we meant to trust.
FM_ZENOH_APT_FINGERPRINT="C09537EDCF795D136EA8CB50829768EDD9BD8B8F"
FM_ZENOH_APT_KEY_URL="https://download.eclipse.org/zenoh/debian-repo/zenoh-public-key"
FM_ZENOH_APT_KEYRING="/etc/apt/keyrings/eclipse-zenoh.gpg"

# Add the Eclipse Zenoh apt repo, verifying its signing key against the pinned
# fingerprint. Every role installer that needs a Zenoh package goes through here,
# so the trust decision is made once rather than three times.
#
# Honours FM_DRY_RUN via the caller's `run` helper being passed in as $1 — the
# installers each own their own dry-run printing, and this takes the command
# runner rather than reaching for a global.
fm_apt_add_zenoh_repo() {
  local runner="$1" tmp
  fm_require_cmd sudo
  fm_require_cmd gpg

  if [ "${FM_DRY_RUN:-0}" = "1" ]; then
    "$runner" sudo install -m 0755 -d /etc/apt/keyrings
    fm_log "  would fetch $FM_ZENOH_APT_KEY_URL, check it is $FM_ZENOH_APT_FINGERPRINT,"
    fm_log "  and write $FM_ZENOH_APT_KEYRING plus /etc/apt/sources.list.d/zenoh.list"
    return 0
  fi

  sudo install -m 0755 -d /etc/apt/keyrings
  tmp="$(mktemp -d)"
  # Every path out of here — a failed fetch, a bad fingerprint, or success — must
  # take the scratch keyring with it, so set the cleanup once rather than at each
  # return.
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL "$FM_ZENOH_APT_KEY_URL" -o "$tmp/key.asc"

  # Import into a throwaway keyring so the fingerprint can be read before the key
  # is trusted anywhere. A mismatch aborts without touching /etc/apt.
  local got
  got="$(gpg --no-default-keyring --keyring "$tmp/ring.gpg" --quiet --import "$tmp/key.asc" \
         && gpg --no-default-keyring --keyring "$tmp/ring.gpg" --list-keys --with-colons \
            | awk -F: '/^fpr:/ {print $10; exit}')"
  if [ "$got" != "$FM_ZENOH_APT_FINGERPRINT" ]; then
    fm_err "the Zenoh apt key does not match the pinned fingerprint"
    fm_err "  expected $FM_ZENOH_APT_FINGERPRINT"
    fm_err "  served   ${got:-<none>}"
    return 1
  fi

  gpg --dearmor <"$tmp/key.asc" >"$tmp/keyring.gpg"
  sudo install -m 0644 "$tmp/keyring.gpg" "$FM_ZENOH_APT_KEYRING"

  sudo install -m 0755 -d /etc/apt/sources.list.d
  printf 'deb [signed-by=%s] https://download.eclipse.org/zenoh/debian-repo/ /\n' \
    "$FM_ZENOH_APT_KEYRING" | sudo tee /etc/apt/sources.list.d/zenoh.list >/dev/null
  sudo apt-get update -qq
}

# Render a config template, substituting exactly the FM_* placeholders named in
# the remaining arguments. Deliberately not envsubst: gettext is not installed by
# default on macOS, and envsubst would also expand any other $-looking text a
# JSON5 config happens to contain. Every named variable must be set and non-empty
# — a config that silently keeps a literal ${FM_ROUTER_ENDPOINT} would start a
# bridge that connects nowhere.
fm_render_template() {
  local src="$1" dest="$2"; shift 2
  local name value body
  [ -f "$src" ] || { fm_err "missing template: $src"; return 1; }
  body="$(cat "$src")"
  for name in "$@"; do
    value="${!name:-}"
    if [ -z "$value" ]; then
      fm_err "$name is unset — fill it in /etc/fm-comms.env before installing"
      return 1
    fi
    # Substitute with bash parameter expansion, not sed: a value containing / or &
    # would otherwise corrupt the output.
    body="${body//\$\{$name\}/$value}"
  done
  # The patterns are literal ${FM_...} text to search for, not expansions.
  # shellcheck disable=SC2016
  if printf '%s' "$body" | grep -q '\${FM_'; then
    fm_err "$src still has unresolved placeholders after rendering:"
    # shellcheck disable=SC2016
    printf '%s' "$body" | grep -o '\${FM_[A-Z_]*}' | sort -u >&2
    return 1
  fi
  printf '%s\n' "$body" >"$dest"
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
