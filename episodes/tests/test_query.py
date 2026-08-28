"""Query routing: every key a caller can send, and every way it can be refused."""

from __future__ import annotations

import json

from episodes.query import answer
from tests.test_store import bag, record, sidecar, write_index


def payload(reply):
    return json.loads(reply.payload.decode("utf-8"))


def test_index_key_returns_the_listing(tmp_path):
    write_index(tmp_path, [record("fm__e1", "e1"), record("fm__e2", "e2")])
    reply = answer("fm/episodes/index", tmp_path)
    assert reply.ok
    assert reply.encoding == "application/json"
    assert [r["episode_id"] for r in payload(reply)] == ["fm__e2", "fm__e1"]


def test_index_on_an_empty_rig_is_an_empty_list_not_an_error(tmp_path):
    reply = answer("fm/episodes/index", tmp_path)
    assert reply.ok
    assert payload(reply) == []


def test_meta_key_returns_one_record(tmp_path):
    write_index(tmp_path, [record("fm__e1", "e1")])
    reply = answer("fm/episodes/fm__e1/meta", tmp_path)
    assert reply.ok
    assert payload(reply)["episode_id"] == "fm__e1"


def test_mcap_key_returns_bytes(tmp_path):
    directory = bag(tmp_path, "e1")
    write_index(tmp_path, [record("fm__e1", "e1")])
    reply = answer("fm/episodes/fm__e1/mcap", tmp_path)
    assert reply.ok
    assert reply.encoding == "application/octet-stream"
    assert reply.payload == (directory / "take.mcap").read_bytes()


def test_an_oversized_mcap_is_refused_with_the_size(tmp_path):
    # One request, one reply: the whole file lands in memory on both ends, so a
    # refusal beats stalling the router.
    bag(tmp_path, "e1")
    write_index(tmp_path, [record("fm__e1", "e1")])
    reply = answer("fm/episodes/fm__e1/mcap", tmp_path, max_mcap_bytes=1)
    assert not reply.ok
    assert "over the 1 limit" in payload(reply)["error"]


def test_a_traversing_id_is_refused(tmp_path):
    reply = answer("fm/episodes/..%2f..%2fetc/mcap", tmp_path)
    assert not reply.ok
    assert "malformed episode id" in payload(reply)["error"]


def test_an_unknown_episode_is_refused(tmp_path):
    write_index(tmp_path, [record("fm__e1", "e1")])
    reply = answer("fm/episodes/fm__e9/meta", tmp_path)
    assert not reply.ok
    assert "unknown episode" in payload(reply)["error"]


def test_an_unknown_resource_is_refused(tmp_path):
    reply = answer("fm/episodes/fm__e1/thumbnail", tmp_path)
    assert not reply.ok
    assert "no such episode resource" in payload(reply)["error"]


def test_a_key_outside_the_prefix_is_refused(tmp_path):
    reply = answer("fm/other/index", tmp_path)
    assert not reply.ok
    assert "not an episode key" in payload(reply)["error"]


def test_leading_and_trailing_slashes_are_tolerated(tmp_path):
    write_index(tmp_path, [record("fm__e1", "e1")])
    assert answer("/fm/episodes/index/", tmp_path).ok


def test_sidecar_key_returns_the_recorder_s_own_bytes(tmp_path):
    bag(tmp_path, "e1")
    body = b'{"episode_id": "fm__e1", "task_id": "pick-v1"}'
    sidecar(tmp_path, "e1", body)
    write_index(tmp_path, [record("fm__e1", "e1")])

    reply = answer("fm/episodes/fm__e1/sidecar", tmp_path)
    assert reply.ok
    assert reply.encoding == "application/json"
    # Byte-for-byte, not re-serialised: the sidecar is the authoritative record.
    assert reply.payload == body


def test_a_missing_sidecar_is_refused_with_a_reason(tmp_path):
    bag(tmp_path, "e1")
    write_index(tmp_path, [record("fm__e1", "e1")])
    reply = answer("fm/episodes/fm__e1/sidecar", tmp_path)
    assert not reply.ok
    assert "no sidecar found" in payload(reply)["error"]


def test_a_traversing_id_never_reaches_the_sidecar_resolver(tmp_path):
    reply = answer("fm/episodes/..%2F..%2Fetc/sidecar", tmp_path)
    assert not reply.ok
    assert "malformed episode id" in payload(reply)["error"]
