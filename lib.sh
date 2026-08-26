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
#
# On stderr, not stdout: `./run.sh render bridge > bridge.json5` must produce a
# config file and not a config file with a banner on line one. Chrome belongs on
# the stream a terminal shows and a redirect drops.
fm_banner() {
  printf '%s\n' "── ${FM_BRAND} ──" >&2
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

# --- Machine identity --------------------------------------------------------
#
# Every host-level fact this repo renders into a config — the rig's namespace, the
# workspace the recordings sit under, which transport the host is even on — comes
# from the machine identity card that fm-setup writes. Reading it here rather than
# retyping those facts in /etc/fm-comms.env is the whole point: a namespace typed
# in two files disagrees the moment a rig is renamed, and the disagreement is
# invisible until a topic lands under a prefix nobody is subscribed to.
#
# This repo only ever reads the card. `fm machine init` in fm-setup writes it.

# The only card schema this checkout understands. A card stamped with anything
# else is refused rather than guessed at: a field that changed meaning between
# versions would otherwise be rendered straight into a running rig's config.
FM_MACHINE_SCHEMA_VERSION=1

# Echo the path to this machine's identity card, whether or not it exists.
# FM_MACHINE_FILE overrides it, which is how a test and a rehearsal container
# point at a card outside the real system paths.
fm_machine_file() {
  if [ -n "${FM_MACHINE_FILE:-}" ]; then
    printf '%s\n' "$FM_MACHINE_FILE"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fm/machine.json" ;;
    *)      printf '%s\n' "/etc/fm/machine.json" ;;
  esac
}

# Return success when this machine has an identity card. A machine without one is
# not broken — a laptop running the desktop app in client mode has no workspace
# and needs no card — so callers ask before they read.
fm_machine_exists() { [ -f "$(fm_machine_file)" ]; }

# fm_machine_get FIELD — echo one field from this machine's card.
#
# Fails when the card is missing, stamped with an unknown schema, unparseable, or
# short of the field, so a caller that substitutes the output into a config can
# never quietly proceed on an empty string.
fm_machine_get() {
  local field="$1" file version value
  file="$(fm_machine_file)"
  if [ ! -f "$file" ]; then
    fm_err "no machine identity card at $file"
    fm_err "  run 'fm machine init' on this host, or set FM_MACHINE_FILE to point at one"
    return 1
  fi
  fm_require_cmd jq || return 1
  version="$(jq -er '.schema_version // empty' "$file" 2>/dev/null)" || {
    fm_err "$file carries no schema_version — it is not a machine identity card"
    return 1
  }
  if [ "$version" != "$FM_MACHINE_SCHEMA_VERSION" ]; then
    fm_err "$file is schema_version $version; this fm-comms reads $FM_MACHINE_SCHEMA_VERSION"
    fm_err "  update fm-comms rather than editing the card — a guessed field would be"
    fm_err "  rendered into a config and run, which is worse than refusing to render"
    return 1
  fi
  value="$(jq -er --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null)" || {
    fm_err "the machine identity card has no '$field': $file"
    return 1
  }
  printf '%s\n' "$value"
}

# fm_machine_get_opt FIELD — echo one OPTIONAL field, or nothing.
#
# Separate from fm_machine_get because the two failures are not the same thing.
# A missing `name` is a broken card and must stop a render; a missing `workload`
# is an ordinary laptop, and a reader that treated the two alike would either
# refuse a valid card or accept a broken one. Absence here is silence and
# success; a card that cannot be trusted at all still fails.
fm_machine_get_opt() {
  local field="$1"
  fm_machine_exists || return 0
  # The card is validated first, through the strict reader on a field every card
  # is required to carry. That keeps an unparseable or wrong-schema card a hard
  # failure here too — only the absence of THIS field is tolerated.
  fm_machine_get schema_version >/dev/null || return 1
  jq -er --arg f "$field" '.[$f] // empty' "$(fm_machine_file)" 2>/dev/null || return 0
}

# fm_machine_namespace [NAME] — echo the ROS namespace derived from a machine
# name, defaulting to this machine's.
#
# Derived, never typed. Hyphens become underscores because a ROS name may not
# contain one: fm-rec-01 becomes fm_rec_01.
fm_machine_namespace() {
  local name="${1:-}"
  [ -n "$name" ] || name="$(fm_machine_get name)" || return 1
  printf '%s\n' "${name//-/_}"
}

# The transport profile this repo implements. The card names the profile every
# process on a host sources, and this is the value it must hold for anything here
# to belong on the machine at all.
FM_COMMS_TRANSPORT=zenoh

# Refuse to configure a host the card puts on another transport.
#
# A rig still on `dds-lan` has not been through the transport migration; placing a
# bridge and a unit on it would start a second, contradictory comms path beside
# the DDS one it is actually running. A machine with no card is not refused —
# that is a laptop in client mode, and it is a legitimate thing to be.
fm_comms_require_transport() {
  local have
  fm_machine_exists || return 0
  have="$(fm_machine_get transport)" || return 1
  [ "$have" = "$FM_COMMS_TRANSPORT" ] && return 0
  if [ "${FM_COMMS_ALLOW_TRANSPORT_MISMATCH:-0}" = "1" ]; then
    fm_warn "  this host's card says transport=$have — continuing anyway (FM_COMMS_ALLOW_TRANSPORT_MISMATCH=1)"
    return 0
  fi
  fm_err "this host's identity card says transport=$have, and fm-comms configures $FM_COMMS_TRANSPORT"
  fm_err "  migrate the host with 'fm machine init --transport $FM_COMMS_TRANSPORT' once its hardware"
  fm_err "  has been validated, or set FM_COMMS_ALLOW_TRANSPORT_MISMATCH=1 to override for a bench test"
  return 1
}

# --- The router's bind address ----------------------------------------------

# Echo this host's tailnet IPv4 address.
#
# The router binds to the tailnet and to nothing else, so this address is the one
# fact its config needs and the one that must never be committed. It is read off
# the running host at render time rather than written into a file: a tailnet
# address is per-host, and a per-host value in git is the bug this repo's
# boundaries name explicitly.
#
# macOS ships the CLI inside the app bundle, which is not on PATH, so the bundle
# path is tried after the plain command rather than instead of it — a Mac with
# the standalone CLI installed must keep using it.
fm_tailnet_ip() {
  local cli ip
  for cli in tailscale /usr/bin/tailscale \
             /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    fm_has_cmd "$cli" || [ -x "$cli" ] || continue
    ip="$("$cli" ip -4 2>/dev/null | head -1)" || continue
    [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
  done
  return 1
}

# Echo the endpoint zenohd listens on: tcp/<tailnet-ip>:<port>.
#
# Binding to every interface (tcp/[::]:7447) was the old default and is what this
# replaces. The router now sits on an always-on office machine that also carries
# an office LAN and, on Rune, an ephemeral CI guest network — listening on all of
# them offers the fleet's whole topic graph to anything that can reach the box.
# The tailnet is already the fleet's authenticated perimeter, so the socket is
# put there and nowhere else.
#
# FM_ROUTER_BIND_IP forces the address for a host with no tailnet — a two-container
# CI smoke, or a bench test on an isolated LAN.
fm_router_listen() {
  local ip="${FM_ROUTER_BIND_IP:-}"
  if [ -z "$ip" ]; then
    ip="$(fm_tailnet_ip)" || {
      fm_err "cannot resolve this host's tailnet address, and the router binds to the tailnet only"
      fm_err "  bring Tailscale up on this host, or set FM_ROUTER_BIND_IP=<addr> for a bench run"
      return 1
    }
  fi
  printf 'tcp/%s:%s\n' "$ip" "${FM_ROUTER_PORT:-7447}"
}

# --- The router on macOS -----------------------------------------------------

# The launchd job's reverse-DNS label, which is also its plist's basename. Named
# once here because the installer loads, unloads, and removes the job by it, and
# a label that disagrees with the filename leaves a daemon nothing can stop.
FM_LAUNCHD_LABEL=ai.firstmotive.zenohd

# Where the rendered configs and the daemon's logs go on a router host.
FM_COMMS_CONF_DIR="${FM_COMMS_CONF_DIR:-/etc/fm-comms}"
FM_COMMS_LOG_DIR_DEFAULT="${FM_COMMS_LOG_DIR_DEFAULT:-/usr/local/var/log/fm-comms}"

# Echo the absolute path to zenohd.
#
# launchd resolves no PATH, so the plist needs the real location. Homebrew's
# prefix differs between Apple silicon and Intel, so it is asked rather than
# assumed; a plain `zenohd` on PATH covers a manual install.
fm_zenohd_bin() {
  local found
  found="$(command -v zenohd 2>/dev/null)" && [ -n "$found" ] && {
    printf '%s\n' "$found"; return 0
  }
  local prefix
  for prefix in "$HOME/.local" /opt/homebrew /usr/local; do
    [ -x "$prefix/bin/zenohd" ] && { printf '%s\n' "$prefix/bin/zenohd"; return 0; }
  done
  fm_err "zenohd is not on this host — install it first (./install.sh --role router)"
  return 1
}

# Return success when this macOS host is itself a virtual machine.
#
# The router belongs on the office Mac mini's HOST, never inside the CI guest it
# also runs. That guest is ephemeral and network isolated by design: a router
# installed there answers nothing while it exists and disappears when the job
# ends, and the failure looks like a fleet-wide outage rather than a misplaced
# install. kern.hv_vmm_present is the kernel's own answer to "am I virtualised",
# so the check does not depend on recognising a particular hypervisor.
fm_macos_is_vm() {
  [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = "1" ]
}

# --- Host configuration ------------------------------------------------------

# Where the fleet-wide values live. Per-host facts moved to the identity card;
# what remains here is what every host in the fleet shares — the router endpoint,
# the DDS domain, the size ceiling — plus any deliberate per-host override.
FM_COMMS_ENV_FILE="${FM_COMMS_ENV_FILE:-/etc/fm-comms.env}"

# Load the env file when the host has one. Missing is not an error: a render can
# be rehearsed on a machine that was never installed, and the caller decides
# whether the values it wanted actually arrived.
# Values are exported, not merely set: systemd hands this file to a unit as an
# EnvironmentFile, and a caller that sources it without `set -a` gets variables
# the child process it then launches cannot see — which is how a foreground run
# and the unit end up reading two different directories.
fm_comms_load_env() {
  [ -f "$FM_COMMS_ENV_FILE" ] || return 0
  set -a
  # shellcheck source=/dev/null
  . "$FM_COMMS_ENV_FILE"
  set +a
}

# fm_comms_resolve — fill every template value for this host.
#
# The order is deliberate: an already-set environment variable wins, then the env
# file, then the identity card. The card is last rather than first so that a
# one-off `FM_RIG_NAMESPACE=… ./run.sh render bridge` still works for a rehearsal,
# while the committed, installed path takes the card and nothing else.
fm_comms_resolve() {
  fm_comms_load_env

  # The rig's namespace and its workspace are per-host facts, and the card is the
  # only place either is written down.
  if [ -z "${FM_RIG_NAMESPACE:-}" ] && fm_machine_exists; then
    FM_RIG_NAMESPACE="$(fm_machine_namespace)" || return 1
  fi
  if [ -z "${FM_EPISODES_DIR:-}" ] && fm_machine_exists; then
    # Recordings sit beside the checkouts under the workspace the card names. A
    # hardcoded ~/recordings is exactly what the workspace field exists to delete.
    FM_EPISODES_DIR="$(fm_machine_get workspace)/recordings" || return 1
  fi

  # Fleet-wide defaults, not host facts: every rig runs the same DDS domain and
  # every router the same port, so these stay constants with an env-file escape.
  FM_ROUTER_PORT="${FM_ROUTER_PORT:-7447}"
  FM_ROS_DOMAIN_ID="${FM_ROS_DOMAIN_ID:-0}"

  export FM_RIG_NAMESPACE FM_EPISODES_DIR FM_ROUTER_PORT FM_ROS_DOMAIN_ID
}

# Echo the bridge profile this rig runs: recorder | processor | robot.
#
# Taken from the card's `workload`, which is the field that answers the question
# `role` cannot — a recorder rig and a processor rig are both jetsons. That was
# the last per-host value anyone still typed into an env file by hand, and it is
# now derived like every other one. FM_BRIDGE_PROFILE still wins when it is set,
# so a bench experiment needs no card edit.
#
# `router` is a workload that runs no bridge, and it is refused here by name: a
# router host asked for a bridge config is a mistake worth stating rather than a
# missing file to report.
fm_comms_bridge_profile() {
  local profile="${FM_BRIDGE_PROFILE:-}"
  if [ -z "$profile" ]; then
    profile="$(fm_machine_get_opt workload)" || return 1
  fi
  if [ "$profile" = router ]; then
    fm_err "this host's workload is 'router' — it runs zenohd, not a bridge"
    fm_err "  install it with: ./install.sh --role router"
    return 1
  fi
  if [ -z "$profile" ]; then
    fm_err "no bridge profile for this host"
    fm_err "  the card names one: fm machine init --workload <recorder|processor|robot>"
    fm_err "  or force one for a bench run: FM_BRIDGE_PROFILE=<profile>"
    return 1
  fi
  # The profile becomes a path segment, so hold it to the shape a filename can
  # take — otherwise a stray value walks out of zenoh/ and renders something else.
  if ! printf '%s' "$profile" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
    fm_err "FM_BRIDGE_PROFILE is malformed: '$profile' (want lowercase, digits, dashes)"
    return 1
  fi
  printf '%s\n' "$profile"
}

# Echo the bridge template this rig's profile selects, or list what exists.
fm_comms_bridge_template() {
  local profile template root known=() candidate name
  root="$(fm_comms_root)"
  profile="$(fm_comms_bridge_profile)" || return 1
  template="$root/zenoh/bridge-$profile.json5"
  if [ ! -f "$template" ]; then
    for candidate in "$root"/zenoh/bridge-*.json5; do
      [ -f "$candidate" ] || continue
      name="${candidate##*/bridge-}"
      known+=("${name%.json5}")
    done
    fm_err "no config for profile '$profile'"
    fm_err "  profiles this checkout carries: ${known[*]:-none}"
    return 1
  fi
  printf '%s\n' "$template"
}

# fm_comms_render KIND [DEST] — render one of this host's config files.
#
# DEST defaults to `-`, meaning stdout: rendering is the step most likely to be
# wrong on a new rig, and a render nobody can read before it is installed can only
# be debugged by installing it. Every caller — the two installers, the episodes
# verb, and `./run.sh render` — comes through here, so what a dry run prints is
# the same text the install writes.
fm_comms_render() {
  local kind="$1" dest="${2:--}" root template
  root="$(fm_comms_root)"
  fm_comms_resolve || return 1

  case "$kind" in
    router)
      # Resolved here rather than in fm_comms_resolve: only the router binds a
      # socket, and a recorder rendering its bridge must not be made to fail
      # because the laptop it is being rehearsed from has no tailnet.
      local listen="${FM_ROUTER_LISTEN:-}"
      if [ -z "$listen" ]; then
        listen="$(fm_router_listen)" || return 1
      fi
      FM_ROUTER_LISTEN="$listen" \
        fm_render_template "$root/zenoh/router.json5" "$dest" FM_ROUTER_LISTEN
      ;;
    bridge)
      template="$(fm_comms_bridge_template)" || return 1
      fm_render_template "$template" "$dest" \
        FM_ROUTER_ENDPOINT FM_RIG_NAMESPACE FM_ROS_DOMAIN_ID
      ;;
    launchd)
      # The router's macOS daemon. Rendered through the same path as the configs
      # so `./run.sh render launchd` shows exactly what an install would load —
      # a plist that can only be inspected by loading it is how a Mac ends up
      # running a daemon nobody can account for.
      local listen="${FM_ROUTER_LISTEN:-}"
      if [ -z "$listen" ]; then
        listen="$(fm_router_listen)" || return 1
      fi
      FM_ZENOHD_BIN="${FM_ZENOHD_BIN:-$(fm_zenohd_bin)}" \
      FM_ROUTER_CONFIG="${FM_ROUTER_CONFIG:-$FM_COMMS_CONF_DIR/router.json5}" \
      FM_COMMS_USER="${FM_COMMS_USER:-${SUDO_USER:-$USER}}" \
      FM_COMMS_LOG_DIR="${FM_COMMS_LOG_DIR:-$FM_COMMS_LOG_DIR_DEFAULT}" \
        fm_render_template "$root/launchd/$FM_LAUNCHD_LABEL.plist.in" "$dest" \
          FM_ZENOHD_BIN FM_ROUTER_CONFIG FM_COMMS_USER FM_COMMS_LOG_DIR
      ;;
    episodes)
      # The checkout and the account that owns it are read off this host rather
      # than written down anywhere: the unit is rendered on the machine it runs on.
      FM_COMMS_CHECKOUT="$root" \
      FM_COMMS_USER="${FM_COMMS_USER:-${SUDO_USER:-$USER}}" \
        fm_render_template "$root/systemd/fm-comms-episodes.service.in" "$dest" \
          FM_COMMS_CHECKOUT FM_COMMS_USER FM_EPISODES_DIR
      ;;
    *)
      fm_err "unknown render kind: $kind (use router | bridge | launchd | episodes)"
      return 1
      ;;
  esac
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
#
# A DEST of `-` writes to stdout, so the same code path serves an install and a
# `./run.sh render` an operator reads before trusting it.
fm_render_template() {
  local src="$1" dest="$2"; shift 2
  local name value body
  [ -f "$src" ] || { fm_err "missing template: $src"; return 1; }
  body="$(cat "$src")"
  for name in "$@"; do
    value="${!name:-}"
    if [ -z "$value" ]; then
      fm_err "$name is unset — it comes from this host's identity card or from $FM_COMMS_ENV_FILE"
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
  if [ "$dest" = "-" ]; then
    printf '%s\n' "$body"
  else
    printf '%s\n' "$body" >"$dest"
  fi
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
