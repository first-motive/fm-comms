#!/usr/bin/env bash
# Show recorded query timeouts. The warning does not contain the requested key.
set -euo pipefail
main() {
  case "${1:-}" in
    --help|-h) echo 'Usage: query-watch [--live] (current router log, read-only)'; return 0 ;;
    ""|--live) ;;
    *) echo "unknown argument: $1" >&2; return 2 ;;
  esac
  local log_file="${FM_COMMS_LOG_DIR:-/usr/local/var/log/fm-comms}/zenohd.log"
  [ -r "$log_file" ] || { echo "log unavailable: $log_file" >&2; return 1; }
  if [ "${1:-}" = --live ]; then
    # -F follows the new inode after the service wrapper rotates the file.
    tail -n 0 -F "$log_file" | grep --line-buffered -E "Didn't receive final reply|Query not found"
    return
  fi
  python3 - "$log_file" <<'PY'
import collections, re, sys
pairs = collections.Counter()
last = {}
pattern = re.compile(r"client/([0-9a-f]+):\d+:\d+ Didn't receive final reply for query .*?client/([0-9a-f]+):")
with open(sys.argv[1]) as stream:
    for raw in stream:
        line = re.sub(r"\x1b\[[0-9;]*m", "", raw)
        match = pattern.search(line)
        if match:
            responder, requester = match.groups()
            pair = (requester, responder)
            pairs[pair] += 1
            last[pair] = line.split()[0]
for pair, count in pairs.most_common():
    print(f"requester={pair[0]} responder={pair[1]} count={count} last={last[pair]}")
print(f"{sum(pairs.values())} timeouts in current file. Key and application are not in this warning.")
print("Map live IDs through the router's read-only @/*/router admin query; never infer a key from these pairs.")
PY
}
main "$@"
