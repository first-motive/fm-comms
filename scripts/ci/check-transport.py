# /// script
# requires-python = ">=3.11"
# dependencies = ["json5"]
# ///
"""Render every transport config and check it against the invariants.

Most of this repo is configuration, which fails in the one way configuration
always fails: it parses, it starts, and it routes nothing. Every check here
exists because the mistake it catches would otherwise reach a rig and look like
a working service.

Three passes, in order of how early they catch a mistake:

1. **Sources.** A committed config carries placeholders and never a real
   address. A tailnet name or an IP in a tracked file is the boundary this repo
   states in its own CLAUDE.md, so it is graded rather than trusted.
2. **Renders.** Every template is rendered against a fixture card and a fixture
   env file, through the repo's own ``./run.sh render`` — not a reimplementation
   of it — and the result must parse as JSON5 with no placeholder left in it.
3. **Invariants.** The rendered configs are then read for the properties the
   fleet depends on: the router binds one non-wildcard endpoint, every bridge is
   a client with multicast off, the recorder never publishes raw frames, and the
   robot never accepts a trajectory from off-rig.

Run it the same way CI does::

    uv run scripts/ci/check-transport.py
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import json5

ROOT = Path(__file__).resolve().parents[2]

# A rendered config must contain none of these. The addresses are what the
# fixtures substitute in, so finding one in a *source* file means a real value
# was committed where a placeholder belongs.
FORBIDDEN_IN_SOURCE = (
    re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"),
    re.compile(r"\.ts\.net\b"),
)
# The exceptions are addresses that carry no information about our fleet: the
# loopback and unspecified addresses appear in prose explaining what NOT to bind.
SOURCE_ADDRESS_ALLOWLIST = {"127.0.0.1", "0.0.0.0", "0.0.0.0.0"}

# One fixture per bridge profile, plus the router. The card is what the render
# now derives the namespace and the bridge profile from, so the matrix is a list
# of cards rather than a list of environment variables.
CARDS = {
    "recorder": {"name": "fm-rec-01", "role": "jetson", "workload": "recorder"},
    "processor": {"name": "fm-rec-02", "role": "jetson", "workload": "processor"},
    "robot": {"name": "fm-rec-03", "role": "jetson", "workload": "robot"},
    "router": {"name": "fm-mac-01", "role": "mac", "workload": "router"},
}

FIXTURE_ENV = """FM_ROUTER_PORT=7447
FM_ROUTER_ENDPOINT=tcp/fixture-router:7447
FM_ROS_DOMAIN_ID=0
FM_EPISODES_MAX_BYTES=536870912
"""

# The bind address the fixture render uses. Deliberately loopback: the check runs
# on a machine with no tailnet, and a fixture that reached for a real address
# would make CI depend on the network it is testing the configuration of.
FIXTURE_BIND_IP = "127.0.0.1"

failures: list[str] = []


def fail(where: str, message: str) -> None:
    failures.append(f"{where}: {message}")


def card_json(profile: str, spec: dict[str, str]) -> str:
    return json.dumps(
        {
            "schema_version": 1,
            "name": spec["name"],
            "role": spec["role"],
            "fleet": "prod",
            "transport": "zenoh",
            "workload": spec["workload"],
            "workspace": "/home/fm/fm",
        }
    )


def render(kind: str, profile: str, spec: dict[str, str], workdir: Path) -> str | None:
    """Render one config through the repo's own render verb."""
    card = workdir / f"machine-{profile}.json"
    card.write_text(card_json(profile, spec))
    envfile = workdir / "fm-comms.env"
    envfile.write_text(FIXTURE_ENV)

    env = dict(os.environ)
    env.update(
        FM_MACHINE_FILE=str(card),
        FM_COMMS_ENV_FILE=str(envfile),
        FM_ROUTER_BIND_IP=FIXTURE_BIND_IP,
        # The plist render needs a zenohd path and an account; neither exists on
        # a CI runner, and neither is what this check is grading.
        FM_ZENOHD_BIN="/opt/homebrew/bin/zenohd",
        FM_COMMS_USER="fm",
    )
    # The banner goes to stdout, so the render is written to a file rather than
    # captured — the same path an install takes.
    out = workdir / f"{kind}-{profile}.rendered"
    result = subprocess.run(
        [str(ROOT / "run.sh"), "render", kind, "-o", str(out)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail(f"render {kind} ({profile})", result.stderr.strip() or "render failed")
        return None
    return out.read_text()


def check_sources() -> None:
    for path in sorted((ROOT / "zenoh").glob("*.json5")):
        body = path.read_text()
        rel = path.relative_to(ROOT)
        if "${FM_" not in body:
            fail(str(rel), "carries no ${FM_...} placeholder — is it a template?")
        for pattern in FORBIDDEN_IN_SOURCE:
            for hit in pattern.findall(body):
                if hit in SOURCE_ADDRESS_ALLOWLIST:
                    continue
                fail(str(rel), f"committed config carries a real endpoint: {hit!r}")


def check_router(config: dict) -> None:
    where = "router.json5"
    if config.get("mode") != "router":
        fail(where, f"mode is {config.get('mode')!r}, expected 'router'")

    endpoints = config.get("listen", {}).get("endpoints", [])
    if len(endpoints) != 1:
        fail(where, f"binds {len(endpoints)} endpoints, expected exactly 1")
    for endpoint in endpoints:
        # The whole point of the move to a tailnet-bound router: a wildcard bind
        # offers the fleet's topic graph to the office LAN and to the CI guest
        # that shares the machine.
        if "[::]" in endpoint or "0.0.0.0" in endpoint:
            fail(where, f"binds a wildcard address: {endpoint!r}")
        if FIXTURE_BIND_IP not in endpoint:
            fail(where, f"bind address was not rendered from the host: {endpoint!r}")

    if config.get("scouting", {}).get("multicast", {}).get("enabled") is not False:
        fail(where, "multicast scouting is not disabled")


# Topic names a bridge must never carry off a rig, and the profile each belongs
# to. Checked by compiling the config's own patterns and matching them, rather
# than by reading the pattern text: a rule is only as good as what it matches,
# and "does this string look safe" is not the same question as "does this regex
# admit /head/color/image_raw".
FORBIDDEN_TOPICS = {
    "recorder": [
        ("publishers", "/head/color/image_raw"),
        ("publishers", "/head/color/image_rect_raw"),
        ("publishers", "/head/aligned_depth_to_color/image_raw"),
        ("publishers", "/wrist/color/image_raw"),
    ],
    "robot": [
        # The arm controllers take this topic directly, bypassing Servo's limits
        # and collision checking. Nothing off-rig may publish it.
        ("subscribers", "/arm_controller/joint_trajectory"),
        ("subscribers", "/joint_trajectory_controller/joint_trajectory"),
    ],
    "processor": [],
}


def matches(pattern: str, topic: str) -> bool:
    """Would this bridge rule admit this topic?

    Anchored deliberately at neither end: the point is to model the plugin's own
    matching, which is a search rather than a full match. An unanchored rule that
    happens to appear inside a forbidden topic name is exactly the mistake this
    is looking for.
    """
    try:
        return re.search(pattern, topic) is not None
    except re.error:
        fail("pattern", f"{pattern!r} is not a valid regular expression")
        return False


def check_bridge(profile: str, config: dict) -> None:
    where = f"bridge-{profile}.json5"
    if config.get("mode") != "client":
        fail(where, f"mode is {config.get('mode')!r}, expected 'client'")
    if config.get("scouting", {}).get("multicast", {}).get("enabled") is not False:
        fail(where, "multicast scouting is not disabled")

    ros2dds = config.get("plugins", {}).get("ros2dds", {})

    # The invariant the plugin itself enforces, at startup, on a rig, by
    # panicking — moved to where it costs a pull request instead of a field
    # visit. zenoh-plugin-ros2dds flattens allow/deny into one untagged enum, so
    # a config carrying both is rejected as "unknown field `deny`", which reads
    # as a typo and is not one.
    if "allow" in ros2dds and "deny" in ros2dds:
        fail(where, "carries both allow and deny — the plugin accepts one or the other, and refuses to start with both")

    allow = ros2dds.get("allow")
    if not allow:
        fail(where, "has no allow block — an absent allowlist routes everything")
        return

    namespace = ros2dds.get("namespace", "")
    if not namespace.startswith("/fm_"):
        fail(where, f"namespace {namespace!r} was not derived from the card's name")

    for kind, topic in FORBIDDEN_TOPICS.get(profile, []):
        for pattern in allow.get(kind, []):
            if matches(pattern, topic):
                fail(where, f"allows {kind[:-1]} {topic!r} via rule {pattern!r}")

    # An unanchored rule is a substring match, which is how a rule written for
    # one topic quietly admits its neighbours. Anchoring is what makes the check
    # above a guarantee rather than a spot test of the names anyone thought of.
    for kind in ("publishers", "subscribers", "service_servers", "service_clients"):
        for pattern in allow.get(kind, []):
            if not (pattern.startswith("^") and pattern.endswith("$")):
                fail(where, f"unanchored {kind[:-1]} rule: {pattern!r}")


def main() -> int:
    check_sources()

    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)

        rendered = render("router", "router", CARDS["router"], workdir)
        if rendered is not None:
            try:
                check_router(json5.loads(rendered))
            except ValueError as exc:
                fail("router.json5", f"rendered output is not valid JSON5: {exc}")

        for profile in ("recorder", "processor", "robot"):
            rendered = render("bridge", profile, CARDS[profile], workdir)
            if rendered is None:
                continue
            try:
                check_bridge(profile, json5.loads(rendered))
            except ValueError as exc:
                fail(f"bridge-{profile}.json5", f"rendered output is not valid JSON5: {exc}")

        # The plist is rendered too: it is generated the same way, from the same
        # inputs, and a malformed one is a router that never starts.
        plist = render("launchd", "router", CARDS["router"], workdir)
        if plist is not None and "${FM_" in plist:
            fail("ai.firstmotive.zenohd.plist", "rendered plist still has a placeholder")

    if failures:
        print("transport check FAILED", file=sys.stderr)
        for line in failures:
            print(f"  {line}", file=sys.stderr)
        return 1
    print("transport check ok: sources, renders, and invariants")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
