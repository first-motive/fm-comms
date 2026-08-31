"""Reading this machine's identity card, including the cards worth refusing."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from episodes.machine import (
    SCHEMA_VERSION,
    MachineCardError,
    card_path,
    read_card,
    recordings_dir,
)

CARD = {
    "schema_version": SCHEMA_VERSION,
    "name": "fm-rec-01",
    "role": "jetson",
    "fleet": "prod",
    "transport": "zenoh",
    "workspace": "/home/fm/fm",
}


def write_card(tmp_path, card):
    path = tmp_path / "machine.json"
    path.write_text(json.dumps(card), encoding="utf-8")
    return path


def test_reads_a_current_card(tmp_path):
    assert read_card(write_card(tmp_path, CARD)) == CARD


def test_recordings_sit_in_the_home_directory(tmp_path):
    # NOT under the card's workspace, which names where the checkouts live. Every
    # other component writes and reads ~/recordings; deriving anything else pointed
    # the queryable at a directory that has never existed on a rig (gate 4.2).
    assert recordings_dir(write_card(tmp_path, CARD)) == Path.home() / "recordings"


def test_absent_card_is_not_an_error(tmp_path):
    # A laptop in client mode has no workspace and no card. The caller falls back
    # rather than failing, which is why this is None and not a raise.
    assert read_card(tmp_path / "nothing.json") is None
    assert recordings_dir(tmp_path / "nothing.json") is None


def test_unknown_schema_version_is_refused(tmp_path):
    # The whole point of the version stamp: a field that changed meaning must not
    # be handed to a running service on the strength of still being present.
    path = write_card(tmp_path, {**CARD, "schema_version": SCHEMA_VERSION + 1})
    with pytest.raises(MachineCardError):
        read_card(path)


def test_unparseable_card_is_refused(tmp_path):
    path = tmp_path / "machine.json"
    path.write_text("{ not json", encoding="utf-8")
    with pytest.raises(MachineCardError):
        read_card(path)


def test_a_card_without_a_workspace_still_resolves(tmp_path):
    # The workspace field is no longer what answers this question, so its absence
    # is not a refusal.
    card = {k: v for k, v in CARD.items() if k != "workspace"}
    assert recordings_dir(write_card(tmp_path, card)) == Path.home() / "recordings"

def test_env_override_names_the_card(tmp_path, monkeypatch):
    path = write_card(tmp_path, CARD)
    monkeypatch.setenv("FM_MACHINE_FILE", str(path))
    assert card_path() == path
    assert read_card() == CARD
