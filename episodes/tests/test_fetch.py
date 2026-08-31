"""Pulling episodes a processor is missing — the half that needs no Zenoh."""

from __future__ import annotations

import json

import pytest
from episodes.fetch import (
    FetchError,
    append_index_line,
    landing,
    missing_episode_ids,
    write_episode,
)
from episodes.store import read_index

from tests.test_store import record, write_index


def test_nothing_local_wants_everything_remote():
    remote = [record("fm__e2", "e2"), record("fm__e1", "e1")]
    assert missing_episode_ids([], remote) == ["fm__e2", "fm__e1"]


def test_an_episode_already_indexed_is_not_refetched():
    remote = [record("fm__e2", "e2"), record("fm__e1", "e1")]
    assert missing_episode_ids([record("fm__e2", "e2")], remote) == ["fm__e1"]


def test_a_malformed_remote_id_is_never_fetched():
    # The index arrives over the network, so an id that could not have been minted
    # here is dropped rather than turned into a path.
    assert missing_episode_ids([], [record("../../etc", "e1")]) == []


def test_landing_keeps_only_the_last_segment_of_a_remote_path(tmp_path):
    place = landing(tmp_path, record("fm__e1", "/home/fm/recordings/e1"))
    assert place.bag_dir == tmp_path.resolve() / "e1"
    assert place.sidecar == tmp_path.resolve() / "e1.episode.json"
    assert place.mcap.parent == place.bag_dir


def test_landing_refuses_a_traversing_remote_path(tmp_path):
    with pytest.raises(FetchError, match="unusable path"):
        landing(tmp_path, record("fm__e1", "/home/fm/recordings/.."))


def test_landing_refuses_a_record_with_no_path(tmp_path):
    with pytest.raises(FetchError, match="no path"):
        landing(tmp_path, {"episode_id": "fm__e1"})


def test_write_episode_lands_both_artifacts_and_no_partials(tmp_path):
    place = landing(tmp_path, record("fm__e1", "e1"))
    write_episode(place, b'{"episode_id": "fm__e1"}', b"\x89MCAP0\r\n")

    assert place.mcap.read_bytes() == b"\x89MCAP0\r\n"
    assert json.loads(place.sidecar.read_text())["episode_id"] == "fm__e1"
    assert not list(tmp_path.glob("**/*.partial"))


def test_the_index_line_points_at_the_local_bag(tmp_path):
    # The remote's path names a machine this one cannot see, and the engine
    # resolves episodes through this field.
    remote = record("fm__e1", "/home/fm/recordings/e1")
    append_index_line(tmp_path, remote)

    landed = read_index(tmp_path)
    assert [r["episode_id"] for r in landed] == ["fm__e1"]
    assert landed[0]["path"] == str((tmp_path / "e1").resolve())


def test_a_fetched_episode_is_not_fetched_again(tmp_path):
    remote = [record("fm__e1", "/home/fm/recordings/e1")]
    write_index(tmp_path, [])
    append_index_line(tmp_path, remote[0])

    assert missing_episode_ids(read_index(tmp_path), remote) == []


def test_a_duplicated_remote_row_is_fetched_once():
    # The recorder's index is append-only and has been seen to carry one episode
    # twice; fetching it twice moves the whole MCAP across the fabric for nothing.
    remote = [record("fm__e1", "e1"), record("fm__e1", "e1")]
    assert missing_episode_ids([], remote) == ["fm__e1"]
