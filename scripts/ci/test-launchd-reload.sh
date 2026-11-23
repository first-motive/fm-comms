#!/usr/bin/env bash
#
# test-launchd-reload.sh — a router reinstall must leave the router loaded.
#
# The bug this exists to keep dead: install-router.sh ran `launchctl bootout`
# and then `launchctl bootstrap` straight after it. bootout returns before
# launchd has removed the job, so the bootstrap failed with "5: Input/output
# error" and the reinstall left Rune with no router (2026-11-23).
#
# fm_launchd_reload_system in lib.sh is driven against a stubbed launchctl that
# keeps listing the old job for a while and can refuse a bootstrap, so the wait
# and the retry are graded without a Mac or a service manager.
#
#   ./scripts/ci/test-launchd-reload.sh
#
# No network, no privileges — nothing here leaves the scratch directory.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$ROOT/lib.sh"

WORKDIR=""
FAILURES=0
cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

# launchctl records every call. `print` reports the job as present until the
# PRINTS_LEFT counter runs out; `bootstrap` fails with launchd's status 5 until
# the FAILS_LEFT counter runs out. sudo runs its command as-is, sleep returns at
# once, so the test takes no wall time.
make_stubs() {
  local bin="$WORKDIR/bin"
  mkdir -p "$bin"

  cat >"$bin/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$FM_TEST_DIR/calls"
take() {
  local n; n="$(cat "$FM_TEST_DIR/$1")"
  [ "$n" -gt 0 ] || return 1
  echo $((n - 1)) >"$FM_TEST_DIR/$1"
}
case "$1" in
  print) take prints_left; exit $? ;;
  bootstrap) if take fails_left; then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi ;;
esac
exit 0
STUB

  printf '#!/usr/bin/env bash\nexec "$@"\n' >"$bin/sudo"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/sleep"
  chmod +x "$bin"/*
}

# Run one reload. $1: how many times `print` still lists the old job, $2: how
# many bootstraps fail. Prints the helper's output, then the exit status.
reload() {
  : >"$WORKDIR/calls"
  echo "$1" >"$WORKDIR/prints_left"
  echo "$2" >"$WORKDIR/fails_left"
  local rc=0 out
  out="$(PATH="$WORKDIR/bin:$PATH" FM_TEST_DIR="$WORKDIR" \
    fm_launchd_reload_system run "$FM_LAUNCHD_LABEL" /Library/LaunchDaemons/test.plist 2>&1)" \
    || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}

# A runner that runs its command, like install-router.sh's `run` outside a dry run.
run() {
  if [ "${FM_DRY_RUN:-0}" = "1" ]; then
    fm_log "  would run: $*"
    return 0
  fi
  "$@"
}

calls() { paste -sd' ' "$WORKDIR/calls"; }

expect() {
  local what="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    fm_ok "  ok   $what"
  else
    fm_err "  FAIL $what"
    fm_err "       expected: $want"
    fm_err "       got:      $got"
    FAILURES=$((FAILURES + 1))
  fi
}

main() {
  WORKDIR="$(mktemp -d)"
  make_stubs

  fm_log "launchd reload"
  local out

  out="$(reload 2 0)"
  expect "waits for the old job to leave before bootstrapping" "$(calls)" \
    "bootout print print print bootstrap"
  expect "a clean reload succeeds" "$(tail -1 <<<"$out")" "rc=0"

  out="$(reload 0 1)"
  expect "a refused bootstrap is retried" "$(calls)" "bootout print bootstrap bootstrap"
  expect "a retry that loads the job succeeds" "$(tail -1 <<<"$out")" "rc=0"

  out="$(reload 0 99)"
  expect "gives up after the configured tries" "$(calls)" \
    "bootout print bootstrap bootstrap bootstrap"
  expect "a job that never loads fails the install" "$(tail -1 <<<"$out")" "rc=1"
  expect "the failure names the command to run by hand" \
    "$(grep -c "sudo launchctl bootstrap system /Library/LaunchDaemons/test.plist" <<<"$out")" "1"

  out="$(FM_LAUNCHD_RELOAD_WAIT=3 reload 99 0)"
  expect "a job that never leaves is waited on for the configured time, then bootstrapped" \
    "$(calls)" "bootout print print print print bootstrap"
  expect "a job that never leaves is named in a warning" \
    "$(grep -c "still lists $FM_LAUNCHD_LABEL after 3s" <<<"$out")" "1"

  out="$(FM_LAUNCHD_RELOAD_WAIT=0 reload 99 99)"
  expect "a stuck old job is named as the cause when nothing loads" \
    "$(grep -c "old $FM_LAUNCHD_LABEL job never left launchd" <<<"$out")" "1"

  out="$(FM_DRY_RUN=1 reload 0 0)"
  expect "a dry run calls no launchctl" "$(calls)" ""
  expect "a dry run prints both commands" "$(grep -c "would run: sudo launchctl" <<<"$out")" "2"

  if [ "$FAILURES" -gt 0 ]; then
    fm_err "$FAILURES check(s) failed — a reinstall could leave the router unloaded"
    return 1
  fi
  fm_ok "launchd reload: all checks passed"
}

main "$@"
