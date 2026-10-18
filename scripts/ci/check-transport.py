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
   fleet depends on: the router binds exactly two non-wildcard endpoints (its LAN
   address and its tailnet address), every bridge is a client with multicast off,
   the recorder never publishes raw frames, the robot never accepts a trajectory
   from off-rig, the anvil workcell accepts nothing inbound at all, the sim host
   carries exactly the simulation contract's topic list with its cameras capped,
   and the cockpit Mac publishes teleop and nothing else.

Run it the same way CI does::

    uv run scripts/ci/check-transport.py
"""

from __future__ import annotations

import copy
import json
import gzip
import math
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
    # The same workload with the card's `robot` field filled in, which is what
    # selects the profile that carries no inbound half at all.
    "robot-anvil": {
        "name": "fm-rob-01",
        "role": "robot",
        "workload": "robot",
        "robot": "anvil-openarm-v2",
    },
    "workstation": {"name": "fm-ws-01", "role": "workstation", "workload": "workstation"},
    "sim": {"name": "fm-ws-01", "role": "workstation", "workload": "sim"},
    "cockpit": {"name": "fm-mac-02", "role": "mac", "workload": "cockpit"},
    "router": {"name": "fm-mac-01", "role": "mac", "workload": "router"},
}

# Every template on disk is a profile, so a new bridge-<profile>.json5 is graded
# the day it lands; one with no fixture card above fails rather than going
# unrendered.
BRIDGE_PROFILES = tuple(sorted(
    path.name.removeprefix("bridge-").removesuffix(".json5")
    for path in (ROOT / "zenoh").glob("bridge-*.json5")
))

# Profiles that accept no inbound topic at all. Each is driven through an
# agent's queryables on the host, so a subscriber rule there is an unreviewed
# command path into the controllers.
NO_INBOUND_PROFILES = ("robot-anvil", "sim")

FIXTURE_ENV = """FM_ROUTER_PORT=7447
FM_ROUTER_ENDPOINT=tcp/fixture-router:7447
FM_ROS_DOMAIN_ID=0
FM_EPISODES_MAX_BYTES=536870912
"""

# The endpoints the fixture render binds. Two of them, because a router binds its
# LAN address and its tailnet address and "exactly two" is the invariant being
# graded. Documentation ranges (RFC 5737, RFC 6598) rather than real addresses:
# the check runs on a machine with neither a LAN worth binding nor a tailnet, and
# a fixture that reached for a real one would make CI depend on the very network
# it is testing the configuration of.
FIXTURE_LAN_ENDPOINT = "tcp/192.0.2.10:7447"
FIXTURE_TAILNET_ENDPOINT = "tcp/100.64.0.1:7447"
FIXTURE_ENDPOINTS = (FIXTURE_LAN_ENDPOINT, FIXTURE_TAILNET_ENDPOINT)

failures: list[str] = []


def fail(where: str, message: str) -> None:
    failures.append(f"{where}: {message}")


def card_json(profile: str, spec: dict[str, str]) -> str:
    card = {
        "schema_version": 1,
        "name": spec["name"],
        "role": spec["role"],
        "fleet": "prod",
        "transport": "zenoh",
        "workload": spec["workload"],
        "workspace": "/home/fm/fm",
    }
    # Optional on every other card, and omitted rather than emptied: a `robot`
    # field present but blank is a different card from one that has none, and
    # only the second is what a recorder rig actually looks like.
    if "robot" in spec:
        card["robot"] = spec["robot"]
    return json.dumps(card)


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
        FM_ROUTER_LISTEN=",".join(FIXTURE_ENDPOINTS),
        # The plist renders need binary paths and an account; none of them exist
        # on a CI runner, and none of them is what this check is grading.
        FM_ZENOHD_BIN="/opt/homebrew/bin/zenohd",
        FM_ZENOH_BRIDGE_BIN="/opt/homebrew/bin/zenoh-bridge-ros2dds",
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
    # Exactly two: the LAN address and the tailnet address. One means a host that
    # resolved only half of what it needs; three means something was appended
    # without anyone deciding what it exposes.
    if len(endpoints) != 2:
        fail(where, f"binds {len(endpoints)} endpoints, expected exactly 2 (LAN and tailnet)")
    for endpoint in endpoints:
        # Still refused, and for the reason the router moved in the first place: a
        # wildcard bind offers the fleet's topic graph to every network the box
        # touches, the CI guest network on Rune included. The office LAN is a
        # place we choose to be reachable; that one is not.
        if "[::]" in endpoint or "0.0.0.0" in endpoint or endpoint.startswith("tcp/*"):
            fail(where, f"binds a wildcard address: {endpoint!r}")
    for expected in FIXTURE_ENDPOINTS:
        if expected not in endpoints:
            fail(where, f"did not render {expected!r} — endpoints came out as {endpoints!r}")

    if config.get("scouting", {}).get("multicast", {}).get("enabled") is not False:
        fail(where, "multicast scouting is not disabled")


# Topic names a bridge must never carry off a rig, and the profile each belongs
# to. Checked by compiling the config's own patterns and matching them, rather
# than by reading the pattern text: a rule is only as good as what it matches,
# and "does this string look safe" is not the same question as "does this regex
# admit /head/color/image_raw".
FORBIDDEN_TOPICS = {
    "recorder": [
        ("publishers", "/vision/left/skeleton"),
        ("publishers", "/vision/right/skeleton"),
        ("subscribers", "/vision/engage"),
        ("subscribers", "/vision/reset"),
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
    "robot-anvil": [
        # The two topics that move an Anvil's arms. Both take a command directly
        # with no limit checking of their own, and the profile stops them by
        # carrying no subscribers at all — which is a guarantee only as long as
        # something tests it.
        ("subscribers", "/commanded_ee_left"),
        ("subscribers", "/follower_l_forward_position_controller/commands"),
        # Compressed only. A raw frame is 20-50x the bytes of the compressed one
        # beside it, and the compressed rule must not widen into it.
        ("publishers", "/cam_wrist_l/image_raw"),
    ],
    "processor": [],
    "workstation": [
        # The workstation runs the sim the same way a rig runs an arm, so the
        # rule that keeps a remote publisher off the controllers holds here too.
        ("subscribers", "/arm_controller/joint_trajectory"),
        ("subscribers", "/joint_trajectory_controller/joint_trajectory"),
        # Sim cameras render locally and are the largest thing this host could
        # put on the wire. Their compressed frames leave on the Jazzy sim
        # bridge (bridge-sim.json5); the raw frames leave on neither.
        ("publishers", "/head/color/image_raw"),
        ("publishers", "/wrist/color/image_raw"),
        ("publishers", "/cam_chest/image_raw"),
        ("publishers", "/cam_wrist_right/image_raw"),
    ],
    "cockpit": [
        # The Mac publishes teleop, and teleop is Servo's jog topics — which the
        # rig rate-limits, collision-checks, and degrades to "stop" on a dropped
        # sample. A trajectory published from a laptop reaches the arm
        # controllers directly and does none of that. bridge-robot.json5 refuses
        # it inbound; this is the other half, refusing it outbound at the source.
        ("publishers", "/fm_rec_03/arm_controller/joint_trajectory"),
        ("publishers", "/fm_rec_03/joint_trajectory_controller/joint_trajectory"),
        # A cockpit that subscribed to raw frames would pull 20-50x the bytes
        # across the link the moment someone opened rviz.
        ("subscribers", "/fm_rec_01/head/color/image_raw"),
        ("subscribers", "/fm_rec_01/head/aligned_depth_to_color/image_raw"),
        ("subscribers", "/fm_rec_01/wrist/color/image_raw"),
    ],
}


# The sim host's topic list, the one README.md states for the `sim` profile:
# state out, and nothing else. `/task/*` and `/perception/*` are held to the
# topics fm-skills publishes today. Graded both ways: every name here must pass,
# every rule must admit a name here, and no rule of any kind may admit a name in
# SIM_OUTSIDE_CONTRACT.
SIM_CONTRACT = {
    "publishers": [
        "/joint_states",
        "/tf",
        "/tf_static",
        "/clock",
        "/rosout",
        "/sim/objects",
        "/sim/markers",
        "/sim/outcome",
        "/task/events",
        "/perception/chest/can",
        "/perception/chest/paper",
        "/perception/wrist/can",
        "/cam_chest/image_raw/compressed",
        "/cam_chest/camera_info",
        "/cam_wrist_right/image_raw/compressed",
        "/cam_wrist_right/camera_info",
    ],
}

# The only two non-literal rules the sim profile may carry, compared string for
# string. The role is the one free part of a camera topic's name.
SIM_CAMERA_RULES = (
    "^/cam_[a-z0-9_]+/image_raw/compressed$",
    "^/cam_[a-z0-9_]+/camera_info$",
)

# The sim profile's forbidden names, graded against every rule kind rather than
# through FORBIDDEN_TOPICS above. Each sits beside the contract where a rule
# written a little too wide would admit it: a sibling under /sim, /task or
# /perception, the raw frame beside a compressed one, the reset service the
# agent alone may call, and the commands that move the simulated arm.
SIM_OUTSIDE_CONTRACT = [
    "/sim/debug",
    "/sim/reset",
    "/task/cmd",
    "/task/pick_place",
    "/perception/wrist/arm",
    "/perception/wrist/paper",
    "/cam_chest/image_raw",
    "/cam_wrist_right/image_raw",
    "/commanded_ee_right",
    "/arm_controller/joint_trajectory",
    "/controller_manager/switch_controller",
    "/robot_description",
]

# Every camera topic the sim host publishes, and the rate it may cross at. A
# camera at its render rate is the largest stream the host produces.
SIM_CAMERA_TOPICS = [t for t in SIM_CONTRACT["publishers"] if t.startswith("/cam_")]
SIM_CAMERA_MAX_HZ = 10.0


# Topic names a bridge MUST carry, and the profile each belongs to. The mirror
# of FORBIDDEN_TOPICS, and the check the workstation profile exists because of: a
# bridge whose allowlist admits nothing holds a session, logs nothing, and looks
# healthy from both ends while the fleet sees an empty topic graph
# (fm-comms#20). An allowlist is graded on what it lets through as well as on
# what it stops.
REQUIRED_TOPICS = {
    "recorder": [("publishers", "/rosout")],
    "processor": [("publishers", "/process/state"), ("subscribers", "/process/start"),
                  ("subscribers", "/process/hands")],
    "robot": [("publishers", "/joint_states")],
    "robot-anvil": [
        ("publishers", "/joint_states"),
        ("publishers", "/hardware_state_controller/state"),
        ("publishers", "/recording_status"),
        ("publishers", "/controls_owner"),
        ("publishers", "/ee_pose_left"),
        ("publishers", "/cam_wrist_l/image_raw/compressed"),
    ],
    # Both halves of the union, which is the whole point of the profile.
    "workstation": [
        ("publishers", "/joint_states"),
        ("publishers", "/tf"),
        ("publishers", "/process/state"),
        ("subscribers", "/process/start"),
    ],
    "sim": [(kind, topic) for kind, topics in SIM_CONTRACT.items() for topic in topics],
    "cockpit": [("subscribers", "/fm_ws_01/joint_states")],
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


def frequency_caps(where: str, ros2dds: dict) -> list[tuple[str, float]]:
    """Parse the bridge's `pub_max_frequencies` rules, `<regex>=<float>` each.

    A rule that does not parse, or whose rate is not a finite positive number,
    is reported rather than read as "no cap" — `nan` compares false against
    every limit and would pass any ceiling check.
    """
    caps = []
    for rule in ros2dds.get("pub_max_frequencies", []):
        pattern, sep, hz = rule.rpartition("=")
        try:
            value = float(hz)
        except ValueError:
            value = math.nan
        if not sep or not math.isfinite(value) or value <= 0:
            fail(where, f"pub_max_frequencies rule {rule!r} is not '<regex>=<finite positive float>'")
            continue
        caps.append((pattern, value))
    return caps


def max_frequency(caps: list[tuple[str, float]], topic: str) -> float | None:
    """The lowest parsed cap that applies to this topic, or None."""
    hits = [hz for pattern, hz in caps if matches(pattern, topic)]
    return min(hits) if hits else None


def check_sim_contract(where: str, ros2dds: dict, allow: dict) -> None:
    """Grade the sim profile against the contract list in both directions."""
    extra_kinds = set(allow) - set(SIM_CONTRACT)
    if extra_kinds:
        fail(where, f"carries rule kinds outside the contract: {sorted(extra_kinds)}")
    # Exact, not sampled: a rule is either one contract topic spelled literally,
    # or one of the two fixed camera patterns, string for string. A wildcard
    # that happens to dodge every probe below still fails here.
    for pattern in allow.get("publishers", []):
        body = pattern[1:-1] if pattern.startswith("^") and pattern.endswith("$") else None
        is_literal = body is not None and re.escape(body) == body and body in SIM_CONTRACT["publishers"]
        if not is_literal and pattern not in SIM_CAMERA_RULES:
            fail(where, f"publisher rule {pattern!r} is neither a literal contract topic nor a fixed camera pattern")
    for kind, rules in allow.items():
        for pattern in rules:
            for topic in SIM_OUTSIDE_CONTRACT:
                if matches(pattern, topic):
                    fail(where, f"{kind[:-1]} rule {pattern!r} admits {topic!r}, which is outside the contract")
    caps = frequency_caps(where, ros2dds)
    for topic in SIM_CAMERA_TOPICS:
        cap = max_frequency(caps, topic)
        if cap is None:
            fail(where, f"camera topic {topic!r} has no pub_max_frequencies cap")
        elif cap > SIM_CAMERA_MAX_HZ:
            fail(where, f"camera topic {topic!r} is capped at {cap} Hz, above {SIM_CAMERA_MAX_HZ}")


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

    # A rig's bridge nests everything it exports under the rig's own name, which
    # is what keeps two rigs from colliding on /head/... The cockpit is the
    # exception and must stay one: it consumes the fleet's already-prefixed keys,
    # so a namespace there would nest them a second time under the Mac's name and
    # nothing would line up. Graded either way — an accidental namespace on the
    # cockpit is as broken as a missing one on a rig.
    namespace = ros2dds.get("namespace", "")
    if profile == "cockpit":
        if namespace not in ("", "/"):
            fail(where, f"the cockpit bridge must carry no namespace, not {namespace!r}")
    elif not namespace.startswith("/fm_"):
        fail(where, f"namespace {namespace!r} was not derived from the card's name")

    # Every cockpit rule is written against a topic the fleet already prefixed.
    # An unprefixed one would match the Mac's own local topics as well, which is
    # how a sim running on the laptop ends up on the fabric.
    if profile == "cockpit":
        for kind in ("publishers", "subscribers"):
            for pattern in allow.get(kind, []):
                if not pattern.startswith("^/fm_"):
                    fail(where, f"{kind[:-1]} rule is not scoped to a rig prefix: {pattern!r}")

    for kind, topic in REQUIRED_TOPICS.get(profile, []):
        if not any(matches(pattern, topic) for pattern in allow.get(kind, [])):
            fail(where, f"carries no {kind[:-1]} rule for {topic!r}")

    # The absence rule, graded as an absence. Every other check here reads the
    # rules a profile carries; this one reads the list an anvil host must not
    # have at all. Its whole safety property is that no key on the fabric reaches
    # a DDS writer on the workcell, and one added rule would restore an inbound
    # path that no forbidden-topic test would notice.
    if profile in NO_INBOUND_PROFILES and allow.get("subscribers"):
        fail(where, f"carries subscriber rules — a {profile} host accepts no inbound topic")

    if profile == "sim":
        check_sim_contract(where, ros2dds, allow)

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


def _ros2dds(config: dict) -> dict:
    return config["plugins"]["ros2dds"]


# Ways the sim profile could drift, each applied to the real rendered config,
# with the finding check_bridge must report for it. A grader that passes a
# broken profile is worse than none, so the grader is graded too.
SIM_MUTATIONS = (
    ("a reset service rule",
     lambda c: _ros2dds(c)["allow"].update(service_servers=["^/sim/reset$"]),
     "rule kinds outside the contract"),
    ("a service client rule",
     lambda c: _ros2dds(c)["allow"].update(service_clients=["^/sim/reset$"]),
     "rule kinds outside the contract"),
    ("a subscriber rule",
     lambda c: _ros2dds(c)["allow"].update(subscribers=["^/commanded_ee_right$"]),
     "accepts no inbound topic"),
    ("a /sim wildcard",
     lambda c: _ros2dds(c)["allow"]["publishers"].append("^/sim/.*$"),
     "outside the contract"),
    ("a camera cap at 30 Hz",
     lambda c: _ros2dds(c).update(pub_max_frequencies=[
         rule.replace("=10", "=30") for rule in _ros2dds(c)["pub_max_frequencies"]]),
     "above 10.0"),
    ("a deleted camera cap",
     lambda c: _ros2dds(c).update(pub_max_frequencies=[
         rule for rule in _ros2dds(c)["pub_max_frequencies"] if "compressed" not in rule]),
     "has no pub_max_frequencies cap"),
    ("a non-finite camera cap",
     lambda c: _ros2dds(c).update(pub_max_frequencies=[
         rule.replace("=10", "=nan") for rule in _ros2dds(c)["pub_max_frequencies"]]),
     "finite positive float"),
    ("a wildcard that dodges every probe",
     lambda c: _ros2dds(c)["allow"]["publishers"].append("^/perception/chest/.*$"),
     "neither a literal contract topic"),
    ("a metacharacter in a literal",
     lambda c: _ros2dds(c)["allow"]["publishers"].append("^/task/even.s$"),
     "neither a literal contract topic"),
    ("a widened camera pattern",
     lambda c: _ros2dds(c)["allow"]["publishers"].append("^/cam_.*/image_raw/compressed$"),
     "neither a literal contract topic"),
)


def check_sim_mutations(config: dict) -> None:
    """Grade each SIM_MUTATIONS case against check_bridge's real findings."""
    for description, mutate, expected in SIM_MUTATIONS:
        broken = copy.deepcopy(config)
        mutate(broken)
        start = len(failures)
        check_bridge("sim", broken)
        found = failures[start:]
        del failures[start:]
        if not any(expected in line for line in found):
            fail("sim self-test", f"{description} was not reported (want {expected!r}, got {found!r})")


def main() -> int:
    check_sources()

    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)

        (workdir / "zenohd.log").write_text(
            "2026-01-01T00:00:00Z WARN south:0:client/bb:3:2 Didn't receive final reply for query south:0:client/aa:6:9: Timeout(5s)!\n"
        )
        query_log = subprocess.run(
            ["bash", str(ROOT / "scripts/query-watch.sh")],
            env={**os.environ, "FM_COMMS_LOG_DIR": str(workdir)},
            capture_output=True, text=True, timeout=10,
        )
        if query_log.returncode or "requester=aa responder=bb" not in query_log.stdout:
            fail("query watch", "requester and responder must follow Zenoh's warning format")

        # Exercise the real service wrapper: rotation must preserve both streams
        # from one uninterrupted child and propagate its exit status.
        log = workdir / "router.log"
        child = "import os,sys; [(print(f'{os.getpid()} out {i:03d}'), print(f'{os.getpid()} err {i:03d}', file=sys.stderr)) for i in range(100)]; sys.exit(7)"
        run = subprocess.run([
            sys.executable, str(ROOT / "scripts/service/router.py"),
            "--log", str(log), "--max-bytes", "1024", "--backups", "5", "--",
            sys.executable, "-u", "-c", child,
        ], capture_output=True, text=True, timeout=20)
        if run.returncode != 7:
            fail("router service", f"child exit status lost: {run.returncode}: {run.stderr}")
        else:
            lines = log.read_text().splitlines()
            archives = list(workdir.glob("router.log.*.gz"))
            for archive in archives:
                with gzip.open(archive, "rt") as stream:
                    lines.extend(stream.read().splitlines())
            if not archives or len(lines) != 200 or len({line.split()[0] for line in lines}) != 1:
                fail("router service", "rotation lost records or restarted the child")
            observed = {" ".join(line.split()[1:]) for line in lines}
            expected = {f"{stream} {i:03d}" for stream in ("out", "err") for i in range(100)}
            if observed != expected:
                fail("router service", "stdout/stderr records changed across rotation")
            if any(path.stat().st_mode & 0o007 for path in [log, *archives]):
                fail("router service", "logs are world-accessible")

        rendered = render("router", "router", CARDS["router"], workdir)
        if rendered is not None:
            try:
                check_router(json5.loads(rendered))
            except ValueError as exc:
                fail("router.json5", f"rendered output is not valid JSON5: {exc}")

        for profile in BRIDGE_PROFILES:
            if profile not in CARDS:
                fail(f"bridge-{profile}.json5", "has no fixture card in CARDS, so it is never rendered")
                continue
            rendered = render("bridge", profile, CARDS[profile], workdir)
            if rendered is None:
                continue
            try:
                config = json5.loads(rendered)
            except ValueError as exc:
                fail(f"bridge-{profile}.json5", f"rendered output is not valid JSON5: {exc}")
                continue
            check_bridge(profile, config)
            if profile == "sim":
                check_sim_mutations(config)

        # Both plists are rendered too: they are generated the same way, from the
        # same inputs, and a malformed one is a service that never starts.
        for kind, card, name in (
            ("launchd", "router", "ai.firstmotive.zenohd.plist"),
            ("launchagent", "cockpit", "ai.firstmotive.zenoh-bridge.plist"),
        ):
            plist = render(kind, card, CARDS[card], workdir)
            if plist is not None and "${FM_" in plist:
                fail(name, "rendered plist still has a placeholder")

    if failures:
        print("transport check FAILED", file=sys.stderr)
        for line in failures:
            print(f"  {line}", file=sys.stderr)
        return 1
    print("transport check ok: sources, renders, and invariants")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
