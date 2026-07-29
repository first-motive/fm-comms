# fm-comms

Zenoh transport for First Motive's inter-device links.

## What

Every First Motive device — the office workstation, the recorder and processor
rigs, a desktop or phone on the tailnet — talks to the others over one comms
fabric. `fm-comms` holds that fabric's configuration and the scripts that deploy
it: a single `zenohd` router on the workstation and a
`zenoh-bridge-ros2dds` per robot, so ROS 2 traffic crosses Wi-Fi and the WAN
without every host needing to see every other host's DDS multicast.

This repo carries **no ROS packages and no application code** — only configs,
systemd units, a compose overlay, and the install scripts that place them. It is
vendored into the [`fm-ros2`](https://github.com/first-motive/fm-ros2) workspace
at `comms/` (and carries a `COLCON_IGNORE` so colcon skips it), the same way
[`fm-docker`](https://github.com/first-motive/fm-docker) is.

Zenoh is opt-in. `fm-ros2` runs the `foxglove` comms profile by default, and
nothing here is reachable until a host selects the `zenoh` profile.

## Status

Scaffold. The front doors and governance are in place; the Zenoh configs, the
systemd units, and the per-role installers the commands below dispatch to land in
the next commit, and `v0.1.0` is cut once they do. `./install.sh --role <role>`
tells you which roles a checkout actually carries.

## Install

Pick the role this host plays:

```bash
./install.sh --role router      # the office workstation: run zenohd
./install.sh --role bridge      # a rig: run zenoh-bridge-ros2dds
./install.sh --role client      # a laptop: the CLI tools only
```

Inspect before running, or see what a run would do:

```bash
curl -fsSL https://raw.githubusercontent.com/first-motive/fm-comms/v0.1.0/install.sh -o install.sh
less install.sh && bash install.sh --role router --dry-run
```

Remove what the installer placed:

```bash
./install.sh uninstall --role router
```

## Usage

`run.sh` dispatches the verbs under `scripts/`:

```bash
./run.sh --help
```

Real endpoints are host-specific and are never committed. The installer writes
them to `/etc/fm-comms.env`; the configs in `zenoh/` carry placeholders that
resolve from it.

## Development

Lint the scripts — the same check CI runs:

```bash
shellcheck scripts/*.sh run.sh install.sh
```

See `CONTRIBUTING.md` for the branch, commit, and PR workflow.

## License

Apache-2.0 — see `LICENSE` and `NOTICE`.
