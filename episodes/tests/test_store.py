"""Episode lookups, including the traversal attempts a network caller can make."""

from __future__ import annotations

import json

import pytest
from episodes.store import (
    EpisodeError,
    find_record,
    read_index,
    resolve_mcap,
    resolve_sidecar,
    valid_episode_id,
)


def write_index(root, records):
    lines = "".join(json.dumps(r, sort_keys=True) + "\n" for r in records)
    (root / "sessions.jsonl").write_text(lines, encoding="utf-8")


def bag(root, name, mcap="take.mcap"):
    directory = root / name
    directory.mkdir()
    (directory / mcap).write_bytes(b"\x89MCAP0\r\n")
    return directory


def record(episode_id, path):
    return {
        "schema_version": 1,
        "episode_id": episode_id,
        "path": str(path),
        "recorded_at": "2026-07-29T10:00:00Z",
        "duration_s": 12.5,
        "drop_gate_passed": True,
        "rows": 4200,
    }


def test_missing_index_reads_as_empty(tmp_path):
    # A rig that has recorded nothing yet is not an error.
    assert read_index(tmp_path) == []


def test_index_is_newest_first(tmp_path):
    write_index(tmp_path, [record("fm__e1", "e1"), record("fm__e2", "e2")])
    assert [r["episode_id"] for r in read_index(tmp_path)] == ["fm__e2", "fm__e1"]


def test_malformed_line_costs_one_row(tmp_path):
    # The recorder appends one line per finalize; a kill mid-append leaves a partial
    # final line, and that must not take the whole listing with it.
    (tmp_path / "sessions.jsonl").write_text(
        json.dumps(record("fm__e1", "e1")) + "\n{ not json\n",
        encoding="utf-8",
    )
    assert [r["episode_id"] for r in read_index(tmp_path)] == ["fm__e1"]


def test_record_without_an_id_is_skipped(tmp_path):
    write_index(tmp_path, [{"schema_version": 1, "path": "e1"}])
    assert read_index(tmp_path) == []


@pytest.mark.parametrize(
    "episode_id",
    ["fm__e1", "e", "A1", "take.2026-07-29", "a_b-c.d"],
)
def test_ids_the_recorder_mints_are_accepted(episode_id):
    assert valid_episode_id(episode_id)


@pytest.mark.parametrize(
    "episode_id",
    [
        "",
        "..",
        "../etc/passwd",
        "a/b",
        "a\\b",
        "/abs",
        ".hidden",
        "-lead",
        "sp ace",
        "nul\x00byte",
        "x" * 129,
    ],
)
def test_ids_that_could_escape_are_rejected(episode_id):
    assert not valid_episode_id(episode_id)


def test_find_record_rejects_a_malformed_id_before_touching_disk(tmp_path):
    with pytest.raises(EpisodeError, match="malformed"):
        find_record(tmp_path, "../../etc/passwd")


def test_find_record_reports_an_unknown_id(tmp_path):
    write_index(tmp_path, [record("fm__e1", "e1")])
    with pytest.raises(EpisodeError, match="unknown episode"):
        find_record(tmp_path, "fm__e9")


def test_resolve_mcap_finds_the_bag(tmp_path):
    bag(tmp_path, "e1")
    write_index(tmp_path, [record("fm__e1", "e1")])
    assert resolve_mcap(tmp_path, "fm__e1").name == "take.mcap"


def test_resolve_mcap_falls_back_to_the_synced_copy(tmp_path):
    # The index was written on the rig, so its path is absolute and belongs to a
    # host that is not this one. rsync lands the bag under this root by name.
    bag(tmp_path, "e1")
    write_index(tmp_path, [record("fm__e1", "/home/rig/recordings/e1")])
    assert resolve_mcap(tmp_path, "fm__e1").parent.name == "e1"


def test_resolve_mcap_refuses_a_path_outside_the_root(tmp_path):
    # The index is a derived file an operator can edit, so its path is input to
    # validate — not a location to trust.
    outside = tmp_path.parent / "outside-root"
    outside.mkdir(exist_ok=True)
    (outside / "secret.mcap").write_bytes(b"nope")
    root = tmp_path / "recordings"
    root.mkdir()
    write_index(root, [record("fm__e1", str(outside))])
    with pytest.raises(EpisodeError, match="no bag directory found"):
        resolve_mcap(root, "fm__e1")


def test_resolve_mcap_refuses_a_traversing_relative_path(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.mcap").write_bytes(b"nope")
    root = tmp_path / "recordings"
    root.mkdir()
    write_index(root, [record("fm__e1", "../outside")])
    with pytest.raises(EpisodeError, match="no bag directory found"):
        resolve_mcap(root, "fm__e1")


def test_resolve_mcap_reports_a_bag_with_no_parts(tmp_path):
    (tmp_path / "e1").mkdir()
    write_index(tmp_path, [record("fm__e1", "e1")])
    with pytest.raises(EpisodeError, match="no mcap found"):
        resolve_mcap(tmp_path, "fm__e1")


def test_resolve_mcap_takes_the_first_part_by_name(tmp_path):
    directory = bag(tmp_path, "e1", mcap="take_0.mcap")
    (directory / "take_1.mcap").write_bytes(b"second")
    write_index(tmp_path, [record("fm__e1", "e1")])
    assert resolve_mcap(tmp_path, "fm__e1").name == "take_0.mcap"


def sidecar(root, name, body=b'{"episode_id": "fm__e1"}'):
    """The recorder writes the sidecar BESIDE the bag dir, not inside it."""
    path = root / (name + ".episode.json")
    path.write_bytes(body)
    return path


def test_resolve_sidecar_finds_the_file_beside_the_bag(tmp_path):
    bag(tmp_path, "e1")
    written = sidecar(tmp_path, "e1")
    write_index(tmp_path, [record("fm__e1", "e1")])
    assert resolve_sidecar(tmp_path, "fm__e1") == written


def test_resolve_sidecar_reports_an_episode_recorded_without_one(tmp_path):
    bag(tmp_path, "e1")
    write_index(tmp_path, [record("fm__e1", "e1")])
    with pytest.raises(EpisodeError, match="no sidecar found"):
        resolve_sidecar(tmp_path, "fm__e1")


def test_resolve_sidecar_refuses_a_path_outside_the_root(tmp_path):
    outside = tmp_path.parent / "outside-sidecar"
    outside.mkdir(exist_ok=True)
    root = tmp_path / "recordings"
    root.mkdir()
    write_index(root, [record("fm__e1", str(outside))])
    with pytest.raises(EpisodeError, match="no bag directory found"):
        resolve_sidecar(root, "fm__e1")
