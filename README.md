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

Real endpoints are host-specific and are never committed. The installer places
`/etc/fm-comms.env` from `systemd/fm-comms.env.example` on first run and stops so
you can fill it in; the configs in `zenoh/` carry `${FM_...}` placeholders that
the installer resolves from it into `/etc/fm-comms/`.

A rig picks its topic set with `FM_BRIDGE_PROFILE` in that file:

```
recorder    head + wrist cameras, hand tracking, capture session, LiDAR
processor   the dataset engine's run state and commands
robot       joint states and TF out, Servo jog commands in
```

Hosts that run the stack in Docker use the compose overlay instead of the
systemd units — same configs, same pinned version:

```bash
./run.sh compose up -d zenoh-bridge
```

## Episodes

A processor rig also serves the recorder's episodes over Zenoh, so the desktop or
a remote contractor can pull one episode instead of waiting for a whole
recordings directory to sync:

```
fm/episodes/index          every indexed episode, newest-first     JSON
fm/episodes/<id>/meta      one episode's index record              JSON
fm/episodes/<id>/mcap      that episode's MCAP bytes               octet-stream
```

```bash
./run.sh episodes install     # enable the service (reads FM_EPISODES_DIR)
./run.sh episodes run         # or serve in the foreground
```

Reads only — the rsync pipeline stays the source of truth for moving recordings
between hosts. Index and fetch, no streaming replay: a query is one request and
one reply, so an MCAP over `FM_EPISODES_MAX_BYTES` is refused rather than stalling
the router.

## Development

Lint the scripts — the same check CI runs:

```bash
shellcheck $(find . -name '*.sh' -not -path './.git/*')
```

Test the episode queryable:

```bash
uv run --project episodes pytest -q
```

See `CONTRIBUTING.md` for the branch, commit, and PR workflow.

## License

Apache-2.0 — see `LICENSE` and `NOTICE`.
