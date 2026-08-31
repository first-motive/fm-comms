"""Pull episodes a processor is missing from a recorder's queryable.

The mirror image of :mod:`episodes.service`, and split the same way: everything
worth testing is a pure function over records and paths, and the Zenoh half does
nothing but carry bytes.

Why this exists: a recorder and a processor on different machines had no working
route between them. ``fm-sync.timer`` needs ``FM_SYNC_SOURCE`` and a rig-to-rig
SSH key that the tailnet policy does not grant, so episodes were relayed by hand
through an operator's laptop (fm-ros2#146). The queryable already served exactly
what a pull needs, over the transport the fleet had just adopted, and nothing
called it.

One episode lands as its whole bag, in this order:

    <root>/<bag>.episode.json   the recorder's authoritative sidecar
    <root>/<bag>/               every file the recorder wrote, under its own name
    <root>/sessions.jsonl       one appended index line

Every file, not just the MCAP: rosbag2 writes ``<name>_0.mcap`` alongside a
``metadata.yaml`` that names it, and the engine drops a directory holding one
without the other ("incomplete bag: metadata.yaml is missing"). Fetching only the
recording, under a name of our own choosing, produced exactly that (gate 4.2).

The index line goes last, and only after the bytes are on disk, so a supervisor
reading the index never sees a row whose episode is half-written — the same
ordering rule ``recordings-sync.sh`` follows.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from episodes.machine import MachineCardError, recordings_dir
from episodes.query import KEY_PREFIX
from episodes.store import SESSION_INDEX_NAME, SIDECAR_SUFFIX, read_index, valid_episode_id


class FetchError(Exception):
    """A pull could not proceed. The message names what to fix."""


@dataclass(frozen=True)
class Landing:
    """Where one fetched episode's artifacts go."""

    bag_dir: Path
    sidecar: Path


def missing_episode_ids(
    local: Iterable[dict[str, Any]], remote: Iterable[dict[str, Any]]
) -> list[str]:
    """Episode ids the remote index has and the local one does not, newest-first.

    Compared on the index alone rather than on the filesystem: the index line is
    appended last, so an id present locally is an episode whose bytes already
    landed. A half-finished pull leaves no line and is simply retried.
    """

    have = {r.get("episode_id") for r in local}
    out = []
    for record in remote:
        episode_id = record.get("episode_id")
        if episode_id and episode_id not in have and valid_episode_id(episode_id):
            out.append(episode_id)
            # The remote index can carry an id twice — a recorder that finalized an
            # episode more than once leaves two rows, and both were fetched, moving
            # 100 MB across the fabric for nothing (gate 4.2). One pull per id.
            have.add(episode_id)
    return out


def landing(recordings_dir: str | Path, record: dict[str, Any]) -> Landing:
    """Where one remote episode's artifacts belong under the local root.

    The remote's ``path`` is a location on another machine, so only its last
    segment is used, and the result is re-resolved and checked against the root.
    A record whose path cannot name a directory under this root is refused rather
    than written somewhere surprising — the index arrives over the network.
    """

    root = Path(recordings_dir).resolve()
    raw = record.get("path")
    if not raw:
        raise FetchError(f"episode {record.get('episode_id')} has no path in the index")

    name = Path(str(raw)).name
    if not name or name in {".", ".."}:
        raise FetchError(f"episode {record.get('episode_id')} has an unusable path: {raw!r}")

    bag_dir = (root / name).resolve()
    if bag_dir.parent != root:
        raise FetchError(f"episode {record.get('episode_id')} would land outside {root}")

    return Landing(bag_dir=bag_dir, sidecar=root / (name + SIDECAR_SUFFIX))


def write_episode(
    place: Landing, sidecar: bytes, files: dict[str, bytes]
) -> None:
    """Put one episode's bytes on disk, nothing appended to the index.

    Each file is written beside its target and renamed into place, so a pull that
    dies midway leaves no truncated artifact for the engine to read as a real one.

    The bag lands before the sidecar deliberately: the bag is the large part and the
    one a pull is likely to die during, so a sidecar on disk means its recording is
    already beside it. The index line, appended by the caller, remains the only
    signal that an episode is complete.
    """

    place.bag_dir.mkdir(parents=True, exist_ok=True)
    for name, payload in sorted(files.items()):
        _atomic_write(place.bag_dir / name, payload)
    _atomic_write(place.sidecar, sidecar)


def append_index_line(recordings_dir: str | Path, record: dict[str, Any]) -> None:
    """Record the episode as present, last, once its bytes have landed.

    The stored ``path`` is rewritten to the local bag directory: the remote's is a
    location on a machine this one cannot see, and the engine resolves episodes
    through this field.
    """

    place = landing(recordings_dir, record)
    local = dict(record)
    local["path"] = str(place.bag_dir)
    index = Path(recordings_dir) / SESSION_INDEX_NAME
    with index.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(local, sort_keys=True) + "\n")


def _atomic_write(path: Path, payload: bytes) -> None:
    temp = path.with_name(path.name + ".partial")
    temp.write_bytes(payload)
    os.replace(temp, path)


def _key(*parts: str) -> str:
    return "/".join((KEY_PREFIX, *parts))


def _get(session, key: str) -> bytes:
    """One query, one reply, or a :class:`FetchError` naming the key that failed."""

    for reply in session.get(key):
        if reply.ok is not None:
            return bytes(reply.ok.payload)
        # The queryable answers a refusal with a message rather than a timeout.
        raise FetchError(f"{key}: {bytes(reply.err.payload).decode('utf-8', 'replace')}")
    raise FetchError(f"{key}: nobody answered — is the recorder's queryable running?")


def pull(session, recordings: Path, limit: int) -> int:
    """Fetch every episode this host is missing. Returns the number that landed."""

    remote = json.loads(_get(session, _key("index")).decode("utf-8"))
    wanted = missing_episode_ids(read_index(recordings), remote)
    if limit > 0:
        wanted = wanted[:limit]
    by_id = {r.get("episode_id"): r for r in remote}

    landed = 0
    for episode_id in wanted:
        record = by_id[episode_id]
        try:
            place = landing(recordings, record)
            sidecar = _get(session, _key(episode_id, "sidecar"))
            names = json.loads(_get(session, _key(episode_id, "files")).decode("utf-8"))
            files = {
                name: _get(session, _key(episode_id, "file", name)) for name in names
            }
            write_episode(place, sidecar, files)
            append_index_line(recordings, record)
        except (FetchError, OSError) as exc:
            # One unfetchable episode must not strand the rest: an oversized MCAP
            # is refused by the queryable by design, and the next one may be fine.
            print(f"episodes: skipped {episode_id}: {exc}", file=sys.stderr)
            continue
        landed += 1
        print(f"episodes: fetched {episode_id} -> {place.bag_dir}", flush=True)
    return landed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Pull missing First Motive episodes from a recorder over Zenoh.",
    )
    parser.add_argument(
        "--recordings-dir",
        default=os.environ.get("FM_EPISODES_DIR", ""),
        help="Where episodes land. Defaults to this machine's card, then ~/recordings.",
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("FM_EPISODES_ZENOH_CONFIG", ""),
        help="Zenoh config file (JSON5). Defaults to the Zenoh defaults.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Fetch at most this many episodes (0 = every missing one).",
    )
    args = parser.parse_args(argv)

    target = args.recordings_dir
    if not target:
        try:
            derived = recordings_dir()
        except MachineCardError as exc:
            print(f"episodes: {exc}", file=sys.stderr)
            return 1
        target = str(derived) if derived is not None else str(Path.home() / "recordings")

    recordings = Path(target).expanduser()
    recordings.mkdir(parents=True, exist_ok=True)

    # Imported here, not at module scope, so --help works on a host without the
    # zenoh wheel and the failure message names the real problem.
    import zenoh

    config = zenoh.Config.from_file(args.config) if args.config else zenoh.Config()
    with zenoh.open(config) as session:
        try:
            landed = pull(session, recordings, args.limit)
        except FetchError as exc:
            print(f"episodes: {exc}", file=sys.stderr)
            return 1
    print(f"episodes: {landed} episode(s) fetched into {recordings}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
