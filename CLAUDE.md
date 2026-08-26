# CLAUDE.md

Guidance for Claude Code and Codex working in the `fm-comms` repo. See the
[README](README.md) for the overview.

## Purpose

`fm-comms` is the Zenoh transport layer for First Motive's inter-device links:
the `zenohd` router config, the per-role `zenoh-bridge-ros2dds` configs, the
systemd units and compose overlay that run them, and the per-platform install
scripts that place the binaries. Part of First Motive's ROS2 stack, vendored into
[`fm-ros2`](https://github.com/first-motive/fm-ros2) at `comms/`.

## Conventions

- Commit and branch rules live in `CONTRIBUTING.md`. Follow them.
- Commits are subject-line-only: `prefix: phrase`. No body.
- Repo is kebab-case.
- Python tooling goes through `uv` — never bare `pip`, `python`, or `poetry`.

## Boundaries

- **No ROS packages, no application code.** This repo is configuration and the
  scripts that deploy it. A node that happens to speak Zenoh belongs in the
  package repo that owns its behaviour, not here.
- **No real endpoints in git.** Committed configs carry `${FM_...}` placeholders
  only; the installer writes the host's actual values to `/etc/fm-comms.env`,
  which is never committed. A hostname or tailnet IP in a tracked file is a bug.
- **Per-host facts come from the machine identity card, never from a file here.**
  The rig's namespace, its workspace, and its transport are read from
  `/etc/fm/machine.json` (`~/.config/fm/machine.json` on macOS, `$FM_MACHINE_FILE`
  under test) through the `fm_machine_*` readers in `lib.sh`. `/etc/fm-comms.env`
  keeps only what every machine in the fleet shares. A per-host value written in
  both places disagrees the day a rig is renamed, and the disagreement surfaces as
  a topic nobody receives rather than as an error.
- **A card with an unknown `schema_version` is refused, not guessed at.** Both
  readers — `fm_machine_get` in `lib.sh`, `episodes/episodes/machine.py` in the
  queryable — check the version before any field is used.
- **Every generated config renders to stdout.** `./run.sh render
  <router|bridge|episodes>` prints exactly what an install would write, and both
  installers print the same text under `--dry-run`. A generation path that can
  only be inspected by running it is not finished.
- **The zenoh version is pinned in one place.** Every install path — brew tap,
  the Eclipse apt repo, the container image — resolves the same pinned version,
  so a router and a bridge never negotiate across a version gap.
- **`COLCON_IGNORE` stays at the root.** This repo is imported into a colcon
  workspace and must never be treated as a package source.

## Testing

Most of this repo is configuration, so CI shellchecks every script and exercises
the `curl | bash` path for both front doors. The one piece of Python — the episode
queryable — carries a real suite:

```bash
shellcheck $(find . -name '*.sh' -not -path './.git/*')
uv run --project episodes pytest -q
uv run scripts/ci/check-transport.py     # renders + invariants, no network
./scripts/ci/smoke-transport.sh          # bridge <-> router session, needs docker
```

`check-transport.py` is the one that grades the configs: it renders every
template against a fixture card, then compiles the allow rules and matches them
against real topic names, so a rule that would admit a raw frame or an inbound
trajectory fails the pull request. `smoke-transport.sh` answers what rendering
cannot — whether a bridge and a router at the pinned version form a session —
by asserting the router's own session count through its admin space.

The queryable's logic lives in `episodes/episodes/store.py`, `query.py`, and
`machine.py`, which import no Zenoh at all; `service.py` is the only module that
opens a session. Keep it that way — it is why the suite needs no router and no
network.

The shell's own card reading is exercised by rendering against a fixture rather
than a real machine:

```bash
FM_MACHINE_FILE=/tmp/machine.json FM_COMMS_ENV_FILE=/tmp/fm-comms.env \
  ./run.sh render bridge
```

## Layout

- `install.sh` / `run.sh` — front doors; thin dispatchers over `scripts/`
- `lib.sh` — shared bootstrap functions, sourced never executed
- `scripts/` — one file per verb, each runnable standalone; `install-<role>.sh`
  is what `install.sh --role <role>` dispatches to, so a new role is one new file
- `zenoh/` — config templates plus `zenoh.version`, the single version pin
- `systemd/` — the two units and the `fm-comms.env` example they read
- `deploy/` — the compose overlay, for hosts that run the stack in containers
