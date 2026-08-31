"""Episode lookups over the recorder's output directory — no Zenoh, no I/O policy.

The recorder is the source of truth: it writes one bag directory per episode plus
an append-only ``sessions.jsonl`` index beside them (see fm-data's
``fm_data_record.core.session_index``). This module reads that layout and nothing
else. It creates nothing, moves nothing, and deletes nothing — the rsync pipeline
that ships recordings around stays the only thing that writes here.

Everything in here is a pure function over a directory path, so the query
behaviour is testable without opening a Zenoh session.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

# The index the recorder appends one line to per finalized episode.
SESSION_INDEX_NAME = "sessions.jsonl"

# Episode ids the recorder mints. Anchored and deliberately narrow: an id arrives
# from the network and is then used to resolve a filesystem path, so anything that
# could traverse (a slash, a dot-dot, a NUL) must fail the match rather than be
# stripped — stripping invites the classic "sanitised into a different valid path"
# bug.
_EPISODE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")


class EpisodeError(Exception):
    """A query could not be answered. The message is safe to return to a caller."""


def valid_episode_id(episode_id: str) -> bool:
    """True when ``episode_id`` is shaped like an id the recorder mints.

    ``..`` is rejected outright: it matches the character class otherwise, and it
    is the one value whose whole purpose is to leave the directory.
    """

    if episode_id == ".." or "/" in episode_id or "\\" in episode_id:
        return False
    return bool(_EPISODE_ID_RE.match(episode_id))


def read_index(recordings_dir: str | Path) -> list[dict[str, Any]]:
    """Every indexed episode, newest-first.

    Mirrors fm-data's reader deliberately: the index is derived, not authoritative,
    so a blank or malformed line is skipped rather than raised. A killed recorder
    leaves a partial final line, and that must cost one row, not the whole listing.
    The file is appended oldest-first, so the result is reversed for a listing view.
    """

    path = Path(recordings_dir) / SESSION_INDEX_NAME
    if not path.is_file():
        return []
    records: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict) and record.get("episode_id"):
            records.append(record)
    records.reverse()
    return records


def find_record(recordings_dir: str | Path, episode_id: str) -> dict[str, Any]:
    """The index record for one episode.

    Raises :class:`EpisodeError` for a malformed id or an unknown one, so a caller
    reports the same shape of failure either way.
    """

    if not valid_episode_id(episode_id):
        raise EpisodeError(f"malformed episode id: {episode_id!r}")
    for record in read_index(recordings_dir):
        if record.get("episode_id") == episode_id:
            return record
    raise EpisodeError(f"unknown episode: {episode_id}")


# The recorder writes its authoritative per-episode metadata beside the bag
# directory, not inside it: ``<bag>/`` and ``<bag>.episode.json`` are siblings
# (fm-data's ``fm_data_record.core.naming.sidecar_path``).
SIDECAR_SUFFIX = ".episode.json"


def resolve_bag(recordings_dir: str | Path, episode_id: str) -> Path:
    """The bag directory for one episode, guaranteed to sit under ``recordings_dir``.

    The index record's ``path`` is a bag *directory* written by the recorder, and it
    may be absolute (recorded on the rig) or relative. Either way the result is
    re-resolved and checked against the recordings root: the index is a derived file
    an operator can edit, so its ``path`` is treated as input to validate rather
    than a location to trust.
    """

    root = Path(recordings_dir).resolve()
    record = find_record(root, episode_id)

    raw = record.get("path")
    if not raw:
        raise EpisodeError(f"episode {episode_id} has no path in the index")

    bag = Path(raw)
    # An absolute path recorded on a different host does not exist here; fall back
    # to the same-named directory under this root, which is what a transfer lands.
    candidates = [bag] if bag.is_absolute() else []
    candidates += [root / bag.name, root / bag]

    for candidate in candidates:
        resolved = candidate.resolve()
        if _within(resolved, root) and resolved.is_dir():
            return resolved

    raise EpisodeError(f"no bag directory found for episode {episode_id}")


def resolve_mcap(recordings_dir: str | Path, episode_id: str) -> Path:
    """The MCAP file for one episode.

    A bag with several MCAP parts resolves to the first by name, which is the
    recorder's write order.
    """

    directory = resolve_bag(recordings_dir, episode_id)
    parts = sorted(directory.glob("*.mcap"))
    if not parts:
        raise EpisodeError(f"no mcap found for episode {episode_id}")
    return parts[0]


# A bag directory is not one file. rosbag2 writes the recording as
# ``<name>_0.mcap`` alongside a ``metadata.yaml`` that names it, and the engine
# refuses a directory carrying one without the other ("incomplete bag:
# metadata.yaml is missing"). Serving only the MCAP, under a name of the client's
# own invention, produced exactly that (gate 4.2).
def list_bag_files(recordings_dir: str | Path, episode_id: str) -> list[str]:
    """Every file in one episode's bag directory, by name, sorted.

    Names only: the caller reconstructs the directory on its own side, and a path
    would let this decide where the other machine writes.
    """

    directory = resolve_bag(recordings_dir, episode_id)
    return sorted(p.name for p in directory.iterdir() if p.is_file())


def resolve_bag_file(
    recordings_dir: str | Path, episode_id: str, name: str
) -> Path:
    """One named file inside an episode's bag directory.

    ``name`` arrives from the network, so it is matched against what the directory
    actually holds rather than joined onto it — a join would accept ``../`` and a
    check after the fact is one refactor away from being dropped.
    """

    directory = resolve_bag(recordings_dir, episode_id)
    for candidate in directory.iterdir():
        if candidate.is_file() and candidate.name == name:
            return candidate
    raise EpisodeError(f"episode {episode_id} has no file {name!r}")


def resolve_sidecar(recordings_dir: str | Path, episode_id: str) -> Path:
    """The ``<bag>.episode.json`` sidecar for one episode.

    Served because it is what makes a fetched episode processable. The index record
    is derived and carries only what a listing view needs; the engine reads the
    sidecar, so an episode pulled without one lands as an episode the processor
    cannot grade.
    """

    directory = resolve_bag(recordings_dir, episode_id)
    sidecar = directory.parent / (directory.name + SIDECAR_SUFFIX)
    if not sidecar.is_file():
        raise EpisodeError(f"no sidecar found for episode {episode_id}")
    return sidecar


def _within(path: Path, root: Path) -> bool:
    """True when ``path`` is ``root`` or sits beneath it, both already resolved."""

    return path == root or root in path.parents
