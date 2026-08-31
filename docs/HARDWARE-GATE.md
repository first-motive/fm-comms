# Hardware Gate

The checklist that decides whether the zenoh-only transport replaces the FastDDS
LAN profile. Every line has a command and a pass criterion, so running the gate
is mechanical: type the command, compare the output, record it in the pull
request. Nothing here asks for judgement.

**The rule: every line green, or nothing merges.** One red line stops the gate.
File it as an issue, leave the pull requests drafted, and run the gate again
after the fix — not the one line, the whole list. A transport is a property of
the fleet, not of the machine you happened to retest.

## Before You Start

Four machines, all converged on the `v*-zenoh.4` pre-release tags (fm-ros2 and
fm-docker stay on `.1` unless they moved):

| Machine | Role | Workload | What it runs |
| --- | --- | --- | --- |
| Rune | office Mac mini | `router` | `zenohd` on the host, under launchd |
| Workstation | GPU tower | `workstation` | the stack, sim, inference, the dataset engine |
| fm-rec-01 | Jetson | `recorder` | cameras, tracker, episode recording |
| Mac | laptop | `cockpit` | the cockpit, `fm` CLI, its own bridge |

The Mac is a bridge host now, not a client. Under this profile its DDS graph is
loopback-only, so without a bridge its ROS tools see nothing the fleet publishes
and sections 3 and 5 cannot run at all.

Record the exact versions once, at the top of the pull request, so a rerun can be
compared against this one:

```bash
fm --version
cat comms/zenoh/zenoh.version
git -C comms describe --tags
```

**Every `ros2` line you run on the Mac: stop the daemon first.**

```bash
ros2 daemon stop
```

The ROS 2 daemon caches the graph it discovered when it started. On a Mac that
has been bridged, unbridged, and rebridged, a stale one answers `ros2 topic hz`
with nothing at all — for ten seconds, then a timeout that reads exactly like a
transport that is not carrying the topic. It is not. Stop the daemon once at the
start of each session on the Mac, and again after the bridge is reinstalled, and
none of the lines below will lie to you.

**A reinstall restarts the service.** `install.sh --role bridge` rerenders the
config and then restarts the unit (Linux) or kickstarts the agent (macOS), and
the router's installer bootouts and bootstraps its LaunchDaemon. The log names
which it did. Before `v0.2.0-zenoh.4` it did neither, and a rig kept running the
profile it had at first start (fm-comms#20).

---

## 1. The Router

### 1.1 zenohd is running on Rune's host

```bash
ssh rune 'launchctl print system/ai.firstmotive.zenohd | head -20'
```

**Pass:** the job prints, `state = running`, and a `pid` is present.
**Fail:** "Could not find service" — the LaunchDaemon was never bootstrapped.

### 1.2 It is on the host, not in the CI guest

```bash
ssh rune '/usr/sbin/sysctl -n kern.hv_vmm_present; /usr/bin/id -un'
```

**Pass:** prints `0` (a physical host), and a username that is **not** `fm-ci`.
**Fail:** `1` means you are inside a guest. Stop — the router is in the wrong
place, and no later line in this gate means anything.

### 1.3 It has exactly two listeners, LAN and tailnet

```bash
ssh rune 'tailscale ip -4'
ssh rune 'ipconfig getifaddr $(route -n get default | awk "/interface:/ {print \$2}")'
nc -z -w 2 <tailnet-address> 7447 && echo tailnet ok
nc -z -w 2 <lan-address> 7447 && echo lan ok
ssh rune 'sudo lsof -nP -iTCP:7447 -sTCP:LISTEN'
```

`sudo`, and not by habit: the router runs under a LaunchDaemon owned by another
account, and an unprivileged `lsof -i` on macOS lists only the caller's own
sockets — it prints nothing while zenohd is up on both addresses (fm-comms#20).
The two `nc` lines are the check that matters and the one a bridge actually
makes; run them from your own machine, on the tailnet and on the office LAN.

**Pass:** both `nc` lines print `ok`, and `lsof` shows exactly two listening
sockets: the address the first command printed (the tailnet) and the address the
second printed (the LAN). Rune carries three LAN addresses, so check the address,
not just the count.
**Fail:** `*:7447`, `0.0.0.0:7447`, or `[::]:7447` — a wildcard bind. The whole
fleet's topic graph is being offered to every network Rune touches, its CI guest
network included.
**Fail:** one socket. Tailnet-only sends the Jetson's compressed camera streams
through WireGuard on its own CPU while it sits one switch port away; LAN-only
leaves an off-site rig with nowhere to connect.

### 1.4 It survives a reboot unattended

```bash
ssh rune 'sudo reboot'
# wait for it to come back, log in to nothing
ssh rune 'launchctl print system/ai.firstmotive.zenohd | grep -E "state|pid"'
```

**Pass:** running again, with nobody having logged in. This is why it is a
LaunchDaemon and not a LaunchAgent.

---

## 2. The Bridges

Run 2.1–2.3 on the workstation, on fm-rec-01, **and on the Mac**, one at a
time. Three bridges, not two: the Mac runs the `cockpit` profile, and that is what
makes the topic lines in section 3 and the deny lines in section 5 meaningful.

On the Mac the commands are local — there is no `fm device ssh` to yourself — and
the service manager is launchd, not systemd. Where a line below says
`fm device ssh <machine> -- '<cmd>'`, run `<cmd>` in a shell on the Mac instead,
and substitute the macOS form given under each line.

### 2.1 The card and the bridge agree

```bash
fm device ssh <machine> -- 'fm machine show --json'
```

On the Mac: `fm machine show --json`.

**Pass:** `transport` is `zenoh`, and `workload` is the machine's real job
(`workstation` / `recorder` / `cockpit`).
**Fail:** `dds-lan` — this machine was never migrated, and everything below it
will fail in a way that looks like a network problem.

### 2.2 The rendered config is the one you expect

```bash
fm device ssh <machine> -- 'cd $(fm machine show --json | jq -r .workspace)/fm-comms && ./run.sh render show'
```

On the Mac: `cd $(fm machine show --json | jq -r .workspace)/fm-comms && ./run.sh render show`.

**Pass:** `namespace` matches the machine name with underscores (`fm-rec-01` →
`fm_rec_01`); `profile` matches the workload and `template` points at the
matching `zenoh/bridge-<profile>.json5`; `router` is Rune's endpoint — the LAN
one on a machine sitting in the office, the tailnet one on a machine that
travels.
**Fail:** any `<unset>` on the first three lines.
**Note:** on the Mac `profile` must read `cockpit`, and on the workstation it
must read `workstation` — `processor` there is the shape that held a session and
carried no joint states (fm-comms#20). `<none — this host runs no
bridge>` means the card was never given a workload; fix it with
`fm machine init --workload cockpit` and re-run the installer.

### 2.3 The bridge holds a session with the router

```bash
fm device ssh <machine> -- 'systemctl is-active fm-zenoh-bridge'
ssh rune 'sudo lsof -nP -iTCP:7447 -sTCP:ESTABLISHED'
```

On the Mac:

```bash
launchctl print "gui/$(id -u)/ai.firstmotive.zenoh-bridge" | grep -E 'state|pid'
```

`lsof` and not the router's admin space: the REST plugin is off unless zenohd is
started with `--rest-http-port`, and a gate line that requires editing the
router's configuration is measuring a router the fleet does not run. The
established connections on 7447 are the sessions, and they are already there to
be read. `sudo` for the same reason as 1.3 — the socket belongs to the
LaunchDaemon's root process, and an unprivileged `lsof -i` on macOS lists only
the caller's own.

**Pass:** `active` on the rigs, `state = running` with a pid on the Mac, and one
`ESTABLISHED` peer on Rune per connected bridge. With both rigs and the Mac up
that is **3 rows**, each showing the peer address of one of them.
**Fail:** running with no row for that machine is the important case — the bridge
started and never connected. Read `journalctl -u fm-zenoh-bridge -n 50` on a rig,
or `tail -50 ~/Library/Logs/fm-comms/zenoh-bridge.err.log` on the Mac.

---

## 3. Topics Across Machines

### 3.1 The workstation's stack publishes

```bash
fm device ssh fm-ws-01 -- 'fm stack up --backend mujoco'
fm device ssh fm-ws-01 -- 'ros2 topic hz /joint_states'
```

**Pass:** ~100 Hz, steady. This is the rate on the workstation's own DDS graph,
before the bridge. What crosses Zenoh is capped lower — see 3.2.

### 3.2 The Mac sees it, wired

```bash
ros2 topic hz /fm_ws_01/joint_states
```

**Pass:** between 45 and 50 Hz, and jitter (the `std dev` line) under 5 ms.

**Where 5 ms comes from.** The figure this line carried first was 1 ms, and no
measurement was ever recorded next to it. The fleet has never met it and probably
never could: wired, on Ethernet, with the office LAN listener reachable, the Mac
reads

```
average rate: 47.505   min: 0.000s max: 0.093s std dev: 0.00339s   window: 1538
```

3.4 ms, against 18.9 ms on Wi-Fi — so the wire is worth 5.6x, which is the real
thing this line should be protecting. A bar the hardware cannot reach turns a
green run into a judgement call every time, so it is set from what a healthy
fleet actually does, with headroom. Lower it when a reading justifies it, and
record the reading here when you do.

**Not 100 Hz, by design.** The `workstation` profile sets
`pub_max_frequencies /joint_states=50`, inherited from `bridge-robot.json5` —
see `comms/zenoh/bridge-workstation.json5`. The bridge downsamples on the
publishing side, so 100 Hz on the workstation's own graph is ~50 Hz on the
fabric, and a reading near 100 here would mean the cap is not being applied.

**Note:** the topic is namespaced. `/joint_states` unprefixed means you are
reading a local publisher, not the workstation's — that is a fail, not a pass.

### 3.3 The Mac sees it, on Wi-Fi

Same command, Ethernet unplugged.

**Pass:** ≥45 Hz sustained over 30 s, with no gap over 0.5 s. No jitter number
on this line — jitter under 1 ms is a wired-LAN figure, and over WireGuard on
Wi-Fi the spacing is uneven by nature without the stream being unusable. Rate
and gaps are what matter here.

This is the line the whole migration is for: AP multicast filtering is what
broke the DDS path, and zenoh's TCP session to the router is not subject to it.

**Worked example — first traffic, 2026-08-27 01:24.** The Mac off-site on Wi-Fi,
through the tailnet to Rune and on to fm-ws-01's sim:

```
average rate: 44.600
  min: 0.000s max: 0.190s std dev: 0.02669s window: 425
```

Steady, no gap near 0.5 s, and the shape this line is looking for. The rate sits
0.4 Hz under the bar above — close enough that it is not a fail on the transport
and not a pass on the criterion either. Rerun it on the gate: ≥45 Hz confirms
the threshold, and a second reading in the 44s is the evidence for lowering it,
recorded in the pull request rather than waved through.

**Fail:** works wired and not wireless means something is still using multicast.
**Fail:** any gap over 0.5 s. A rate that averages well while stalling for half a
second is a teleop link that drops commands.

### 3.4 The Jetson sees nothing it did not ask for

A rig's bridge subscribes to its own command topics and nothing else — no
profile lets one rig read another rig's state, and that is the design, not a
gap (fm-comms#22, decided 2026-08-27: the Mac is the fleet's one observer; a
recorder has no business consuming the workstation's joints). So the line
inverts: on the Jetson, under the rig's own loopback profile, the fleet must
be absent.

```bash
fm device ssh fm-rec-01 -- \
  'source ~/fm/fm_ros2/scripts/env/comms.sh; ros2 topic list | grep -c "^/fm_ws_01/"'
```

**Pass:** `0`. Deny-by-default holds between rigs.
**Fail:** any `/fm_ws_01/*` on the rig — a profile grew an inbound rule nobody
decided on.

### 3.5 The sim-first loop runs on zenoh, on one host

The open question this gate exists to answer. In CI the loop job is pinned to
`none` — the profile that changes nothing, leaving the container image's own
middleware alone, which is what that job had before the verbs sourced a transport
at all. On the default it fails there with the stack up, `/joint_states`
advertised, and no sample reaching the first `ros2 topic echo --once` inside 20
seconds. Cyclone's participant ceiling on loopback was one cause and is fixed;
whatever remains is not understood, and a container with no bridge and no router
in it is the wrong place to chase it.

The workstation runs the same stack for real, so it is answered here.

The loop runs on the workstation's HOST, in the fm_ros2 checkout; it drives the
sim container itself. That container is the `fm` service of the **`fm-sim`**
compose project — `docker compose -p fm-sim -f docker/compose.yaml -f
docker/compose.linux.yaml` — which is a different project from the processor's
`fm-processor`, so the two never share a container.

```bash
fm device ssh fm-ws-01 -- 'cd $(fm machine show --json | jq -r .workspace)/fm_ros2 && ./scripts/ci/loop.sh'
```

**Pass:** the loop completes — an episode reaches the index, a manifest is
written, and at least one episode in it is usable.
**Fail:** `no /joint_states message within 20s`. Capture the QoS on both ends
from a second shell while the stack is up — that is the first thing to read —
and attach it to the pull request:

```bash
fm device ssh fm-ws-01 -- 'cd $(fm machine show --json | jq -r .workspace)/fm_ros2 && \
  docker compose -p fm-sim -f docker/compose.yaml -f docker/compose.linux.yaml \
  exec -T fm /ros_entrypoint.sh ros2 topic info /joint_states --verbose'
```

Do not merge — with this red, a workstation on zenoh cannot record.

Once green, drop the `FM_TRANSPORT=none` pin on the loop job in
`.github/workflows/ci.yml`.

---

## 4. Episode Traffic

### 4.1 Record on the Jetson

```bash
fm device ssh fm-rec-01 -- 'fm episode record --duration 10'
```

**Pass:** the command returns after the recorder confirms the episode closed —
not on a timeout. A sidecar and an index entry land.

```bash
fm device ssh fm-rec-01 -- 'fm episode list'
```

**Pass:** the new episode is listed, newest first, with a non-zero size.

### 4.2 The workstation can read it

```bash
fm device ssh fm-ws-01 -- 'fm dataset process'
fm device ssh fm-ws-01 -- 'fm dataset verify'
```

**Pass:** the episode the Jetson recorded reaches the workstation and INGESTS —
the manifest names it, with its real size and duration read from the bag.

```
{"bag_size_bytes": 105731629, "duration_s": 11.669821, ...}
```

**Not** "at least one usable episode", which this line asked for until 2026-08-31
and which a recorder rig cannot currently produce. The engine grades an episode
against a frame clock, and its ingest decodes robot state, not the streams an
egocentric human capture carries: `sensor_msgs/msg/Imu` and `CompressedImage`
both land in `ignored_topics`, so `decoded_topics` comes back empty and every
choice of `ingest.frame_clock_topic` reads `frame_count: 0` — including
`/head/imu`, which the bag carries 2358 messages of. No profile override reaches
it; the engine has to learn those types (fm-data).

That is a data-engine gap, not a transport one, so it does not belong in this
gate. What this line is for — an episode crossing from the recorder to the
processor and being read — is what it now checks.

Grading a human-capture episode returns here when the engine supports it; IMU
transforms on the rig are the intended path.

**Fail:** the episode never arrives, or arrives and cannot be read (an incomplete
bag, a missing `metadata.yaml`).

### 4.3 MCAP bytes did not travel as topics

```bash
ros2 topic list | grep -c mcap
```

**Pass:** `0`. Episode payloads are served through the queryable on demand;
streaming them as topics is what the allowlists exist to prevent.

---

## 5. The Deny Rules Hold

These are the lines that prove the allowlists are real. Each one **must fail to
arrive** — a pass here is silence.

### 5.1 A trajectory published from the Mac does not reach the robot

From the Mac:

```bash
ros2 topic pub --once /fm_rec_01/arm_controller/joint_trajectory \
  trajectory_msgs/msg/JointTrajectory '{}'
```

On the rig, at the same time:

```bash
fm device ssh fm-rec-01 -- 'timeout 10 ros2 topic echo --once /arm_controller/joint_trajectory'
```

**Pass:** the rig's `echo` times out with nothing received.
**Fail:** a message arrives. Stop the gate — an off-rig publisher can reach the
arm controllers directly, bypassing Servo's limits and collision checking. This
is the most serious failure on the list.

Two allowlists have to fail for a message to arrive: the Mac's own `cockpit`
bridge refuses to route the topic outbound, and `bridge-robot` refuses it
inbound. Both are checked by `check-transport.py` on every pull request; this
line proves it on the wire.

### 5.2 Raw frames do not cross from the recorder

From the Mac:

```bash
ros2 topic list | grep image_raw
```

**Pass:** no output. Only `.../compressed` topics appear under
`/fm_rec_01/`.
**Fail:** any `image_raw` — the allowlist admits a raw stream, which will
saturate the link the first time someone subscribes.

Confirm the raw topics still exist on the rig itself, so this is an allowlist
result and not a dead camera:

```bash
fm device ssh fm-rec-01 -- 'ros2 topic list | grep -c image_raw'
```

**Pass:** non-zero. Local consumers still get raw frames.

---

## 6. The Escape Hatch Still Works

### 6.1 One host can fall back to FastDDS

On the Mac:

```bash
FM_TRANSPORT=dds-lan ros2 topic list
```

**Pass:** the profile announces `dds-lan: FastDDS pinned to <ip>`, and the
command runs. It will see a different (smaller) graph — that is expected, and is
the point: the two profiles are separate worlds.

### 6.2 The card path works too

```bash
./run.sh --comms dds-lan && fm machine show --json | jq -r .transport
./run.sh --comms zenoh   && fm machine show --json | jq -r .transport
```

**Pass:** `dds-lan`, then `zenoh`. Leave the machine on `zenoh`.

---

## 7. Failure Recovery

### 7.1 The Jetson reconnects after a power cycle

Pull the Jetson's power. Wait for it to boot. Touch nothing.

```bash
ssh rune 'sudo lsof -nP -iTCP:7447 -sTCP:ESTABLISHED'
```

**Pass:** the Jetson's row comes back within two minutes, with no manual step,
and the row count returns to what it was before the cycle. Same reading as 2.3,
and for the same reason: no flag on zenohd, no configuration change.

### 7.2 The recorders survive a workstation reboot

This is the line the router moved to Rune for.

```bash
fm device ssh fm-ws-01 -- 'sudo reboot'
# while it is down:
fm device ssh fm-rec-01 -- 'systemctl is-active fm-zenoh-bridge'
ros2 topic list | grep fm_rec_01
```

**Pass:** the Jetson's bridge stays `active` throughout, and its topics stay
visible from the Mac while the workstation is down.
**Fail:** the fleet loses discovery when the workstation reboots — the router is
still on the wrong machine.

---

## After A Green Run

Only when every line above is green:

1. Delete the FastDDS LAN profile (`scripts/env/dds-lan.sh`), keeping
   `FM_TRANSPORT=dds-lan` documented as unsupported. Drop the `FM_TRANSPORT=none`
   pin the loop CI job still holds (section 3.5).
2. Take the pull requests out of draft.
3. Merge in order: `.github` → `fm-comms` → `fm-docker` → `fm-ros2` →
   `.github-private`.
4. Cut the real tag set.
5. Move ADR 0004 from Proposed to Accepted, recording Rune as the router host.

Paste the completed checklist into the fm-comms pull request. A gate whose
results live only in someone's terminal did not happen.
