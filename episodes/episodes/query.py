"""Route an episode query key to its answer — still no Zenoh in sight.

One queryable serves the whole ``fm/episodes/**`` space, so something has to turn
a key into a payload. That routing is the part worth testing, and it needs no
session, so it lives here as a pure function and :mod:`episodes.service` does
nothing but carry bytes between Zenoh and this.

    fm/episodes/index          the whole index, newest-first     JSON
    fm/episodes/<id>/meta      one episode's index record        JSON
    fm/episodes/<id>/sidecar   that episode's .episode.json      JSON
    fm/episodes/<id>/mcap      that episode's MCAP bytes         octet-stream
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from episodes.store import (
    EpisodeError,
    find_record,
    read_index,
    resolve_mcap,
    resolve_sidecar,
    valid_episode_id,
)

# Keys are served under this prefix, matching the queryable the service declares.
KEY_PREFIX = "fm/episodes"

# Ceiling on a single MCAP reply. A query is one request and one reply — there is
# no streaming here by design (see the deferred scope in the plan), so the whole
# file lands in memory on both ends. Past this, refusing with a clear message beats
# stalling a router and every peer behind it. Raise it deliberately, or rsync the
# bag instead.
DEFAULT_MAX_MCAP_BYTES = 512 * 1024 * 1024


@dataclass(frozen=True)
class Reply:
    """One reply to send. ``ok`` false means send it as an error instead."""

    key: str
    payload: bytes
    encoding: str
    ok: bool = True


def _json(key: str, value: object) -> Reply:
    return Reply(
        key=key,
        payload=json.dumps(value, sort_keys=True).encode("utf-8"),
        encoding="application/json",
    )


def _error(key: str, message: str) -> Reply:
    return Reply(
        key=key,
        payload=json.dumps({"error": message}).encode("utf-8"),
        encoding="application/json",
        ok=False,
    )


def answer(
    key: str,
    recordings_dir: str | Path,
    max_mcap_bytes: int = DEFAULT_MAX_MCAP_BYTES,
) -> Reply:
    """Answer one query key.

    Never raises: a caller is a network peer, so every failure comes back as an
    error reply carrying a message rather than killing the handler and leaving the
    query to time out.
    """

    parts = key.strip("/").split("/")
    prefix = KEY_PREFIX.split("/")
    if parts[: len(prefix)] != prefix:
        return _error(key, f"not an episode key: {key}")
    rest = parts[len(prefix) :]

    if rest == ["index"]:
        try:
            return _json(key, read_index(recordings_dir))
        except OSError as exc:
            return _error(key, f"could not read the index: {exc}")

    if len(rest) == 2 and rest[1] in {"meta", "sidecar", "mcap"}:
        episode_id, what = rest
        if not valid_episode_id(episode_id):
            return _error(key, f"malformed episode id: {episode_id!r}")
        if what == "meta":
            return _meta(key, recordings_dir, episode_id)
        if what == "sidecar":
            return _sidecar(key, recordings_dir, episode_id)
        return _mcap(key, recordings_dir, episode_id, max_mcap_bytes)

    return _error(key, f"no such episode resource: {key}")


def _meta(key: str, recordings_dir: str | Path, episode_id: str) -> Reply:
    try:
        return _json(key, find_record(recordings_dir, episode_id))
    except EpisodeError as exc:
        return _error(key, str(exc))
    except OSError as exc:
        return _error(key, f"could not read the index: {exc}")


def _sidecar(key: str, recordings_dir: str | Path, episode_id: str) -> Reply:
    try:
        path = resolve_sidecar(recordings_dir, episode_id)
    except EpisodeError as exc:
        return _error(key, str(exc))
    except OSError as exc:
        return _error(key, f"could not resolve the sidecar: {exc}")

    # Returned as the recorder's own bytes rather than re-serialised JSON: the
    # sidecar is the authoritative record, and a caller writing it to disk must
    # end up with the file the rig has, byte for byte.
    try:
        payload = path.read_bytes()
    except OSError as exc:
        return _error(key, f"could not read the sidecar: {exc}")

    return Reply(key=key, payload=payload, encoding="application/json")


def _mcap(
    key: str, recordings_dir: str | Path, episode_id: str, max_bytes: int
) -> Reply:
    try:
        path = resolve_mcap(recordings_dir, episode_id)
    except EpisodeError as exc:
        return _error(key, str(exc))
    except OSError as exc:
        return _error(key, f"could not resolve the episode: {exc}")

    try:
        size = path.stat().st_size
        if size > max_bytes:
            return _error(
                key,
                f"episode {episode_id} is {size} bytes, over the {max_bytes} limit — "
                "rsync the bag instead of fetching it over Zenoh",
            )
        payload = path.read_bytes()
    except OSError as exc:
        return _error(key, f"could not read the mcap: {exc}")

    return Reply(key=key, payload=payload, encoding="application/octet-stream")
