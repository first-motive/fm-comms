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
```

The queryable's logic lives in `episodes/episodes/store.py` and `query.py`, which
import no Zenoh at all; `service.py` is the only module that opens a session. Keep
it that way — it is why the suite needs no router and no network.

## Layout

- `install.sh` / `run.sh` — front doors; thin dispatchers over `scripts/`
- `lib.sh` — shared bootstrap functions, sourced never executed
- `scripts/` — one file per verb, each runnable standalone; `install-<role>.sh`
  is what `install.sh --role <role>` dispatches to, so a new role is one new file
- `zenoh/` — config templates plus `zenoh.version`, the single version pin
- `systemd/` — the two units and the `fm-comms.env` example they read
- `deploy/` — the compose overlay, for hosts that run the stack in containers
