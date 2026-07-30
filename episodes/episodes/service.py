"""The Zenoh queryable that serves episodes off a processor rig.

Deliberately thin: it opens a session, declares one queryable over
``fm/episodes/**``, and hands every key to :func:`episodes.query.answer`. All the
behaviour worth testing lives in :mod:`episodes.query` and :mod:`episodes.store`,
which import no Zenoh at all — so the test suite needs no router and no network.

Why a queryable rather than publishing episodes onto topics: an episode is pulled
on demand by whoever wants it, and there may be thousands of them. Publishing
would push every episode at every subscriber; a query fetches exactly one.

The rsync pipeline remains the source of truth for moving recordings between
hosts. This serves reads only, and opens nothing for writing.
"""

from __future__ import annotations

import argparse
import os
import signal
import sys
from pathlib import Path

from episodes.query import DEFAULT_MAX_MCAP_BYTES, KEY_PREFIX, answer


def _handler(recordings_dir: Path, max_bytes: int):
    """Build the queryable callback. Closes over config so Zenoh needs none of it."""

    def handle(query) -> None:  # noqa: ANN001 - zenoh.Query, imported lazily
        key = str(query.key_expr)
        reply = answer(key, recordings_dir, max_bytes)
        import zenoh

        encoding = zenoh.Encoding(reply.encoding)
        if reply.ok:
            query.reply(reply.key, reply.payload, encoding=encoding)
        else:
            # An error reply, not a dropped query: a caller waiting on a fetch
            # deserves the reason rather than a timeout.
            query.reply_err(reply.payload, encoding=encoding)

    return handle


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Serve First Motive episodes over Zenoh (index + MCAP fetch).",
    )
    parser.add_argument(
        "--recordings-dir",
        default=os.environ.get("FM_EPISODES_DIR", str(Path.home() / "recordings")),
        help="Recorder output directory holding sessions.jsonl and the bags.",
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("FM_EPISODES_ZENOH_CONFIG", ""),
        help="Zenoh config file (JSON5). Defaults to the Zenoh defaults.",
    )
    parser.add_argument(
        "--max-mcap-bytes",
        type=int,
        default=int(os.environ.get("FM_EPISODES_MAX_BYTES", DEFAULT_MAX_MCAP_BYTES)),
        help="Refuse to serve an MCAP larger than this in one reply.",
    )
    args = parser.parse_args(argv)

    recordings = Path(args.recordings_dir).expanduser()
    if not recordings.is_dir():
        print(f"episodes: {recordings} is not a directory", file=sys.stderr)
        return 1

    # Imported here, not at module scope, so --help works on a host without the
    # zenoh wheel and the unit's failure message names the real problem.
    import zenoh

    config = zenoh.Config.from_file(args.config) if args.config else zenoh.Config()

    key = f"{KEY_PREFIX}/**"
    with zenoh.open(config) as session:
        session.declare_queryable(key, _handler(recordings, args.max_mcap_bytes))
        print(f"episodes: serving {key} from {recordings}", flush=True)
        # Nothing else to do on this thread; Zenoh runs the handler. Wait for the
        # signal systemd sends on stop rather than spinning.
        signal.sigwait({signal.SIGINT, signal.SIGTERM})
    print("episodes: stopped", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
