"""This machine's identity card, as the queryable needs it.

The card is the one file that says what a machine is — its name, its role, its
fleet, its transport, and the workspace every First Motive checkout lives under.
``fm machine init`` in fm-setup writes it; nothing here ever does.

The queryable reads it for one thing: confirming this machine is a First Motive
rig at all. Where the recordings sit is NOT on the card — every other component
(the recorder's own default, the processor's bind mounts, ``fm episode``,
``recordings-sync``) uses ``~/recordings``, and this module derived
``<workspace>/recordings`` instead. On a real rig the card's ``workspace`` names
where the checkouts live (``/home/fm/fm``), so the queryable looked in
``/home/fm/fm/recordings``, a directory that has never existed, and the service
died at start with the bags sitting in ``/home/fm/recordings`` (gate 4.2).

``FM_EPISODES_DIR`` remains the way a rig that keeps its bags on a mounted volume
says so.

Two rules that look like caution and are not. A card stamped with a schema version
this code does not know is refused rather than read, because a field that changed
meaning between versions would otherwise be handed to a running service. And an
absent card is not an error: a laptop in client mode has no workspace and needs no
card, so the caller gets ``None`` and falls back to whatever it was told directly.
"""

from __future__ import annotations

import json
import os
import platform
from pathlib import Path

#: The only card schema this module understands. Bumped in lockstep with the
#: writer in fm-setup, never guessed past.
SCHEMA_VERSION = 1


class MachineCardError(Exception):
    """The card exists but cannot be trusted — unparseable, or a schema we do not know."""


def card_path() -> Path:
    """Where this machine's card lives, whether or not it is there.

    ``FM_MACHINE_FILE`` overrides the platform default, which is how a test and a
    rehearsal container point at a card outside the real system paths.
    """
    override = os.environ.get("FM_MACHINE_FILE")
    if override:
        return Path(override)
    if platform.system() == "Darwin":
        config_home = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
        return Path(config_home) / "fm" / "machine.json"
    return Path("/etc/fm/machine.json")


def read_card(path: Path | None = None) -> dict | None:
    """Return the card as a dict, or ``None`` when this machine has none.

    Raises :class:`MachineCardError` when a card is present but unreadable or
    stamped with an unknown ``schema_version``.
    """
    path = path or card_path()
    if not path.is_file():
        return None
    try:
        card = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise MachineCardError(f"{path} is not readable as JSON: {exc}") from exc
    if not isinstance(card, dict):
        raise MachineCardError(f"{path} is not a machine identity card")
    version = card.get("schema_version")
    if version != SCHEMA_VERSION:
        raise MachineCardError(
            f"{path} is schema_version {version!r}; this build reads {SCHEMA_VERSION}"
        )
    return card


def recordings_dir(path: Path | None = None) -> Path | None:
    """Where this machine's recordings sit, or ``None`` when it has no card.

    ``~/recordings`` — the same location the recorder writes to and the processor
    mounts. The card is still read, so a machine that is not a rig (no card) gets
    ``None`` and the caller falls back to what it was told directly.
    """
    card = read_card(path)
    if card is None:
        return None
    return Path.home() / "recordings"
