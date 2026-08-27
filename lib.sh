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

# Echo this host's LAN IPv4 address: the address on the interface
# FM_ROUTER_LAN_IF names, or on the one the default route already uses.
#
# Picked by interface, never by guess. Rune carries three LAN addresses — wired,
# Wi-Fi, and the bridge its CI guests sit behind — and "the first address that is
# not loopback" binds the router to whichever one the kernel happened to list
# first. That is a socket nobody can predict, and a fleet that stops routing
# after an unrelated reboot changed the order.
#
# A Tailscale interface is refused here rather than accepted as a LAN one. The
# router binds the tailnet separately; a host whose default route runs over an
# exit node would otherwise resolve the same address twice and bind one socket
# where the gate expects two.
fm_lan_ip() {
  local iface="${FM_ROUTER_LAN_IF:-}" ip
  case "$(uname -s)" in
    Darwin)
      [ -n "$iface" ] || iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')"
      [ -n "$iface" ] || {
        fm_err "this host has no default route — name the LAN interface with FM_ROUTER_LAN_IF=<if>"
        return 1
      }
      ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
      ;;
    *)
      [ -n "$iface" ] || iface="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
      [ -n "$iface" ] || {
        fm_err "this host has no default route — name the LAN interface with FM_ROUTER_LAN_IF=<if>"
        return 1
      }
      ip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
      ;;
  esac
  case "$iface" in
    tailscale*|utun*)
      fm_err "'$iface' is a Tailscale interface, and the router binds the tailnet separately"
      fm_err "  name the LAN interface explicitly: FM_ROUTER_LAN_IF=<if>"
      return 1
      ;;
  esac
  if [ -z "$ip" ]; then
    fm_err "interface '$iface' carries no IPv4 address"
    fm_err "  name the LAN interface explicitly: FM_ROUTER_LAN_IF=<if>"
    return 1
  fi
  printf '%s\n' "$ip"
}

# Echo the endpoints zenohd binds, one per line.
#
# Two of them, and exactly two: the LAN address and the tailnet address. In the
# office a rig reaches the router over plain TCP on the switch it is already
# plugged into; off-site, or on a Wi-Fi link that filters multicast, the same rig
# reaches it through the tailnet. Tailnet-only would push the Jetson's compressed
# camera streams through WireGuard on its own CPU while it sits one switch port
# away, for no gain. A rig that moves changes its FM_ROUTER_ENDPOINT, not its
# transport.
#
# Neither address is written into a tracked file: both are read off the host at
# render time, because both are per-host facts.
#
# Binding every interface (tcp/[::]:7447) was the old default and is what this
# replaces — it offers the fleet's whole topic graph to anything that can reach
# the box, the CI guest network on Rune included.
#
# FM_ROUTER_BIND_IP forces a single address on a host with neither a LAN nor a
# tailnet worth binding: a two-container CI smoke, or a bench test.
fm_router_listen() {
  local port="${FM_ROUTER_PORT:-7447}" lan tailnet
  if [ -n "${FM_ROUTER_BIND_IP:-}" ]; then
    printf 'tcp/%s:%s\n' "$FM_ROUTER_BIND_IP" "$port"
    return 0
  fi
  lan="$(fm_lan_ip)" || {
    fm_err "cannot resolve this host's LAN address, and the router binds the LAN and the tailnet"
    fm_err "  set FM_ROUTER_LAN_IF=<if>, or FM_ROUTER_BIND_IP=<addr> for a bench run"
    return 1
  }
  tailnet="$(fm_tailnet_ip)" || {
    fm_err "cannot resolve this host's tailnet address, and the router binds the LAN and the tailnet"
    fm_err "  bring Tailscale up on this host, or set FM_ROUTER_BIND_IP=<addr> for a bench run"
    return 1
  }
  printf 'tcp/%s:%s\n' "$lan" "$port"
  printf 'tcp/%s:%s\n' "$tailnet" "$port"
}

# Echo the endpoints this host will actually bind, one per line, honouring the
# override. Every consumer goes through here — the render and the installer's
# after-the-fact check — so what is verified is what was rendered.
#
# FM_ROUTER_LISTEN overrides the whole list, written however an operator wrote it
# — commas, spaces, or both — so a bench host can name its own endpoints without
# the two resolvers above running at all.
fm_router_listen_list() {
  local endpoints="${FM_ROUTER_LISTEN:-}"
  if [ -n "$endpoints" ]; then
    # Both separators map to a newline; the set form is deliberate, not a
    # word-for-word replacement.
    # shellcheck disable=SC2020
    printf '%s' "$endpoints" | tr ', ' '\n\n' | grep -v '^$' || true
    return 0
  fi
  fm_router_listen
}

# Echo those endpoints as the JSON array the router template drops in.
fm_router_listen_json() {
  local endpoints line out=""
  endpoints="$(fm_router_listen_list)" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    out="${out:+$out, }\"$line\""
  done <<EOF
$endpoints
EOF
  [ -n "$out" ] || { fm_err "no listen endpoint resolved for the router"; return 1; }
  printf '[%s]\n' "$out"
}

# fm_tcp_listening ADDR PORT — return success when something accepts a TCP
# connection at that address.
#
# The question an installer actually has is "can a bridge connect to this?", and
# a connection is the only thing that answers it. Enumerating sockets answers a
# narrower one, and on macOS it answers it wrong for anyone but the socket's
# owner (see fm_tcp_listeners).
#
# -w is the connect timeout on both the BSD nc macOS ships and the GNU one on a
# rig, so the probe cannot hang an install on a half-open address.
fm_tcp_listening() {
  local addr="$1" port="$2"
  if fm_has_cmd nc; then
    nc -z -w 2 "$addr" "$port" >/dev/null 2>&1
    return
  fi
  # No nc on this host: bash speaks TCP itself, under a timeout. Unbounded, this
  # hangs until the kernel gives up on a filtered address — an installer that
  # stops for minutes with nothing on screen, which is worse than the wrong
  # answer it replaced.
  local timeout_cmd=""
  for timeout_cmd in timeout gtimeout ""; do
    [ -n "$timeout_cmd" ] || break
    fm_has_cmd "$timeout_cmd" && break
  done
  if [ -n "$timeout_cmd" ]; then
    # The address and port reach the inner shell as its own positional
    # parameters, so they must not expand here.
    # shellcheck disable=SC2016
    "$timeout_cmd" 2 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$addr" "$port" >/dev/null 2>&1
    return
  fi
  fm_err "no way to test a TCP connection on this host: install netcat (nc) or coreutils (timeout)"
  return 1
}

# fm_tcp_listeners PORT — echo the listening sockets on PORT, from a vantage
# point that can see every user's.
#
# Privileged on purpose. macOS shows an unprivileged `lsof -i` only the sockets
# of the caller's own processes, and the router runs under a LaunchDaemon whose
# account is not the one running the installer — so the plain command printed
# nothing while zenohd was up on both addresses, and the installer called that
# "nothing is listening" (fm-comms#20). Escalation is attempted non-interactively
# first so a probe in a script cannot sit on a password prompt.
#
# Echoes nothing and still succeeds when it cannot look: the caller decides what
# an unreadable socket table means, and for the installer that is a skipped
# wildcard check rather than a failed install.
fm_tcp_listeners() {
  local port="$1" out
  out="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  if [ "$(id -u)" != 0 ] && fm_has_cmd sudo; then
    out="$(sudo -n lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  return 0
}

# --- The router on macOS -----------------------------------------------------

# The launchd job's reverse-DNS label, which is also its plist's basename. Named
# once here because the installer loads, unloads, and removes the job by it, and
# a label that disagrees with the filename leaves a daemon nothing can stop.
FM_LAUNCHD_LABEL=ai.firstmotive.zenohd

# The Mac bridge's LaunchAgent label, on the same rule. A LaunchAgent and not a
# Daemon: the Mac is a laptop running a cockpit, and its bridge is only useful
# while someone is logged in and looking at the fleet.
FM_LAUNCHD_BRIDGE_LABEL=ai.firstmotive.zenoh-bridge

# Where the rendered configs and the daemon's logs go on a router host.
FM_COMMS_CONF_DIR="${FM_COMMS_CONF_DIR:-/etc/fm-comms}"
FM_COMMS_LOG_DIR_DEFAULT="${FM_COMMS_LOG_DIR_DEFAULT:-/usr/local/var/log/fm-comms}"

# Where the Mac bridge keeps its rendered config and its logs. Under the user's
# own config dir, not /etc: a LaunchAgent runs as the logged-in account, and an
# install that needed sudo to place a laptop's bridge config would be the only
# step on the Mac that did.
FM_COMMS_USER_CONF_DIR="${FM_COMMS_USER_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/fm-comms}"
FM_COMMS_USER_LOG_DIR="${FM_COMMS_USER_LOG_DIR:-$HOME/Library/Logs/fm-comms}"

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

# Echo the absolute path to zenoh-bridge-ros2dds, on the same rule as zenohd:
# launchd resolves no PATH, so the plist needs the real location.
fm_zenoh_bridge_bin() {
  local found
  found="$(command -v zenoh-bridge-ros2dds 2>/dev/null)" && [ -n "$found" ] && {
    printf '%s\n' "$found"; return 0
  }
  local prefix
  for prefix in "$HOME/.local" /opt/homebrew /usr/local /usr; do
    [ -x "$prefix/bin/zenoh-bridge-ros2dds" ] && {
      printf '%s\n' "$prefix/bin/zenoh-bridge-ros2dds"; return 0
    }
  done
  fm_err "zenoh-bridge-ros2dds is not on this host — install it first (./install.sh --role bridge)"
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

# fm_comms_env_unfilled KEY... — echo the named keys this host has not filled in.
#
# The installers place /etc/fm-comms.env from the example and then have to decide
# whether to stop and ask for it to be edited. "The file was just created" is the
# wrong test: the example already carries every fleet-wide default, and a router
# needs nothing else from it — stopping there made the first run of the router
# installer always fail, and pre-placing the file by hand the workaround
# (fm-comms#17, Rune, 2026-08-26). The right test is whether the values THIS role
# needs are actually present, which is what this answers.
#
# A key is unfilled when it is empty or still carries the example's CHANGEME.
fm_comms_env_unfilled() {
  local key value missing=""
  fm_comms_load_env
  for key in "$@"; do
    value="${!key:-}"
    case "$value" in
      "" | *CHANGEME*) missing="${missing:+$missing }$key" ;;
    esac
  done
  [ -z "$missing" ] || printf '%s\n' "$missing"
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

# Echo the bridge profile this machine runs: recorder | processor | robot |
# workstation | cockpit.
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
    fm_err "  the card names one: fm machine init --workload <recorder|processor|robot|workstation|cockpit>"
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
      # Resolved here rather than in fm_comms_resolve: only the router binds
      # sockets, and a recorder rendering its bridge must not be made to fail
      # because the laptop it is being rehearsed from has no tailnet.
      #
      # The template takes the whole JSON array, not one address, because the
      # router binds two: the LAN and the tailnet.
      local listen
      listen="$(fm_router_listen_json)" || return 1
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
      FM_ZENOHD_BIN="${FM_ZENOHD_BIN:-$(fm_zenohd_bin)}" \
      FM_ROUTER_CONFIG="${FM_ROUTER_CONFIG:-$FM_COMMS_CONF_DIR/router.json5}" \
      FM_COMMS_USER="${FM_COMMS_USER:-${SUDO_USER:-$USER}}" \
      FM_COMMS_LOG_DIR="${FM_COMMS_LOG_DIR:-$FM_COMMS_LOG_DIR_DEFAULT}" \
        fm_render_template "$root/launchd/$FM_LAUNCHD_LABEL.plist.in" "$dest" \
          FM_ZENOHD_BIN FM_ROUTER_CONFIG FM_COMMS_USER FM_COMMS_LOG_DIR
      ;;
    launchagent)
      # The Mac bridge's LaunchAgent, on the same rule as the router's plist.
      # The domain travels in the plist rather than an EnvironmentFile: launchd
      # reads no such thing, and the Mac has no /etc/fm-comms.env to read.
      FM_ZENOH_BRIDGE_BIN="${FM_ZENOH_BRIDGE_BIN:-$(fm_zenoh_bridge_bin)}" \
      FM_BRIDGE_CONFIG="${FM_BRIDGE_CONFIG:-$FM_COMMS_USER_CONF_DIR/bridge.json5}" \
      FM_CYCLONEDDS_URI="${FM_CYCLONEDDS_URI:-file://$FM_COMMS_USER_CONF_DIR/cyclonedds.xml}" \
      FM_COMMS_LOG_DIR="${FM_COMMS_LOG_DIR:-$FM_COMMS_USER_LOG_DIR}" \
        fm_render_template "$root/launchd/$FM_LAUNCHD_BRIDGE_LABEL.plist.in" "$dest" \
          FM_ZENOH_BRIDGE_BIN FM_BRIDGE_CONFIG FM_CYCLONEDDS_URI FM_COMMS_LOG_DIR \
          FM_ROS_DOMAIN_ID
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
      fm_err "unknown render kind: $kind (use router | bridge | launchd | launchagent | episodes)"
      return 1
      ;;
  esac
}

# Fingerprint of the key Eclipse signs the Zenoh debian repo with. Pinned here so
# a swapped key is caught: fetching a key over TLS only proves who served it,
# not that it is the key we meant to trust.
#
# This is the PRIMARY fingerprint of "Eclipse Zenoh <zenoh-dev@eclipse.org>"
# (created 2024-11-18). The Release file is signed by its subkey
# C09537EDCF795D136EA8CB50829768EDD9BD8B8F; the check below accepts a match on
# either, because gpg lists the primary first and a pin on the subkey alone
# never matched the served key (fm-ws-01, 2026-08-26).
FM_ZENOH_APT_FINGERPRINT="0ABC5913672BBE50921B3B9395D19EA1F7DF9E8E"
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
  # return. `${tmp:-}` because a RETURN trap can fire again in the caller's
  # frame, where `tmp` is unset and `set -u` would abort the install after the
  # repo was already added (fm-ws-01, 2026-08-26).
  trap 'rm -rf "${tmp:-}"; trap - RETURN' RETURN
  curl -fsSL "$FM_ZENOH_APT_KEY_URL" -o "$tmp/key.asc"

  # Import into a throwaway keyring so the fingerprint can be read before the key
  # is trusted anywhere. A mismatch aborts without touching /etc/apt.
  local got
  got="$(gpg --no-default-keyring --keyring "$tmp/ring.gpg" --quiet --import "$tmp/key.asc" \
         && gpg --no-default-keyring --keyring "$tmp/ring.gpg" --list-keys --with-colons \
            | awk -F: '/^fpr:/ {print $10}')"
  # Every fingerprint on the key — primary and subkeys — one per line.
  if ! printf '%s\n' "$got" | grep -qx "$FM_ZENOH_APT_FINGERPRINT"; then
    fm_err "the Zenoh apt key does not match the pinned fingerprint"
    fm_err "  expected $FM_ZENOH_APT_FINGERPRINT"
    fm_err "  served   $(printf '%s' "${got:-<none>}" | tr '\n' ' ')"
    return 1
  fi

  gpg --dearmor <"$tmp/key.asc" >"$tmp/keyring.gpg"
  sudo install -m 0644 "$tmp/keyring.gpg" "$FM_ZENOH_APT_KEYRING"

  sudo install -m 0755 -d /etc/apt/sources.list.d
  printf 'deb [signed-by=%s] https://download.eclipse.org/zenoh/debian-repo/ /\n' \
    "$FM_ZENOH_APT_KEYRING" | sudo tee /etc/apt/sources.list.d/zenoh.list >/dev/null
  sudo apt-get update -qq
}

# fm_file_differs NEW OLD — true when NEW is not what OLD already holds.
#
# A missing OLD counts as different: the first install of a config is a change by
# any reading. The installers use this to choose between `restart` and
# `try-restart`, and to name in the log which one they did — an operator reading a
# reinstall cannot otherwise tell one that swapped the allow-list from one that
# changed nothing.
fm_file_differs() {
  [ -f "$2" ] || return 0
  ! cmp -s "$1" "$2"
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

# --- macOS binaries (router, client, and the Mac bridge share this) ----------

# Echo the version the binary at $1 reports, or nothing.
fm_zenoh_version_at() {
  "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

# Kept under its old name: install-client.sh and install-router.sh both call it.
fm_zenohd_version_at() { fm_zenoh_version_at "$1"; }

# Where a macOS install of either binary lands. The same place a manual install
# goes, and the place fm_zenohd_bin and fm_zenoh_bridge_bin look first.
FM_MACOS_BIN_DIR="${FM_MACOS_BIN_DIR:-$HOME/.local/bin}"

# fm_install_zenoh_macos REPO ASSET_STEM BINARY VERSION — fetch one Eclipse
# standalone build and put it on this Mac at exactly that version.
#
# The Homebrew tap has no per-version formula — it ships whatever is current
# (1.10.0 at the time of writing against a 1.9.0 pin) and Homebrew now refuses an
# untrusted tap without an interactive `brew trust`. Neither is acceptable for a
# fleet that must match the rigs' apt pin exactly and install unattended. So:
# keep a binary that already matches the pin, otherwise fetch Eclipse's
# standalone build of exactly that version.
#
# Both macOS binaries come from the same shape of release asset — zenohd from
# eclipse-zenoh/zenoh, zenoh-bridge-ros2dds from eclipse-zenoh/zenoh-plugin-ros2dds
# — so the fetch, the unzip, and the version assertion are written once. A second
# copy is how a router and a Mac bridge end up installed by two slightly
# different rules.
fm_install_zenoh_macos() {
  local repo="$1" stem="$2" binary="$3" version="$4"
  local existing
  if existing="$(command -v "$binary" 2>/dev/null)" && [ -n "$existing" ]; then
    if [ "$(fm_zenoh_version_at "$existing")" = "$version" ]; then
      fm_log "  $binary $version already at $existing"
      return 0
    fi
    fm_warn "  $existing is not $version — installing the pinned build beside it"
  fi
  local arch
  case "$(uname -m)" in
    arm64 | aarch64) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) fm_err "unsupported macOS arch: $(uname -m)"; return 1 ;;
  esac
  local name="${stem}-${version}-${arch}-apple-darwin-standalone.zip"
  local url="https://github.com/${repo}/releases/download/${version}/${name}"
  local dest="$FM_MACOS_BIN_DIR"
  fm_log "  fetching $url"
  if [ "${FM_DRY_RUN:-0}" = "1" ]; then
    fm_log "  would install $binary $version to $dest"
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL --proto '=https' -o "$tmp/$name" "$url"
  unzip -q -o "$tmp/$name" -d "$tmp/x"
  mkdir -p "$dest"
  # The zip carries the binary plus its plugins as flat files.
  find "$tmp/x" -type f \( -name "$binary" -o -name '*.dylib' \) -exec cp {} "$dest/" \;
  chmod +x "$dest/$binary"
  rm -rf "$tmp"
  local got
  got="$(fm_zenoh_version_at "$dest/$binary")"
  [ "$got" = "$version" ] || {
    fm_err "installed $binary reports '$got', expected $version"
    return 1
  }
  fm_log "  $binary $version installed at $dest/$binary"
  # A fresh shell may not have ~/.local/bin on PATH yet; every plist takes the
  # absolute path, so launchd does not care. Later steps in this same run resolve
  # through fm_zenohd_bin / fm_zenoh_bridge_bin, which check this dir explicitly.
  export PATH="$dest:$PATH"
}

fm_install_zenohd_macos() {
  fm_install_zenoh_macos eclipse-zenoh/zenoh zenoh zenohd "$1"
}

fm_install_zenoh_bridge_macos() {
  fm_install_zenoh_macos eclipse-zenoh/zenoh-plugin-ros2dds \
    zenoh-plugin-ros2dds zenoh-bridge-ros2dds "$1"
}
