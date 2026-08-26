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

Four machines, all converged on the `v*-zenoh.1` pre-release tags:

| Machine | Role | Workload | What it runs |
| --- | --- | --- | --- |
| Rune | office Mac mini | `router` | `zenohd` on the host, under launchd |
| Workstation | GPU tower | `processor` | the stack, sim, inference |
| fm-rec-01 | Jetson | `recorder` | cameras, tracker, episode recording |
| Mac | laptop | — | the cockpit, `fm` CLI |

Record the exact versions once, at the top of the pull request, so a rerun can be
compared against this one:

```bash
fm --version
cat comms/zenoh/zenoh.version
git -C comms describe --tags
```

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

### 1.3 It listens on the tailnet interface and nowhere else

```bash
ssh rune 'lsof -nP -iTCP:7447 -sTCP:LISTEN'
ssh rune 'tailscale ip -4'
```

**Pass:** exactly one listening socket, and its address is the tailnet address
the second command printed.
**Fail:** `*:7447`, `0.0.0.0:7447`, or `[::]:7447` — a wildcard bind. The whole
fleet's topic graph is being offered to the office LAN and to Rune's guest
network.

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

Run 2.1–2.3 on the workstation and on fm-rec-01, one at a time.

### 2.1 The card and the bridge agree

```bash
fm device ssh <machine> -- 'fm machine show --json'
```

**Pass:** `transport` is `zenoh`, and `workload` is the rig's real job
(`processor` / `recorder`).
**Fail:** `dds-lan` — this machine was never migrated, and everything below it
will fail in a way that looks like a network problem.

### 2.2 The rendered config is the one you expect

```bash
fm device ssh <machine> -- 'cd $(fm machine show --json | jq -r .workspace)/fm-comms && ./run.sh render show'
```

**Pass:** `namespace` matches the machine name with underscores (`fm-rec-01` →
`fm_rec_01`); `profile` matches the workload; `router` is Rune's tailnet
endpoint.
**Fail:** any `<unset>` on the first three lines.

### 2.3 The bridge holds a session with the router

```bash
fm device ssh <machine> -- 'systemctl is-active fm-zenoh-bridge'
ssh rune 'curl -s http://127.0.0.1:8000/@/local/router | jq ".[0].value.sessions | length"'
```

**Pass:** `active`, and the session count on Rune rises by one per bridge. With
both rigs and the Mac connected it should read **3**.
**Fail:** `active` with a session count of 0 is the important case — the bridge
started and never connected. Read
`journalctl -u fm-zenoh-bridge -n 50` on the rig.

> The router's REST admin space is not on by default. For the gate, start
> `zenohd` with `--rest-http-port 8000` bound to loopback, and take the flag off
> afterwards.

---

## 3. Topics Across Machines

### 3.1 The workstation's stack publishes

```bash
fm device ssh fm-ws-01 -- 'fm stack up --backend mujoco'
fm device ssh fm-ws-01 -- 'ros2 topic hz /joint_states'
```

**Pass:** ~100 Hz, steady.

### 3.2 The Mac sees it, wired

```bash
ros2 topic hz /fm_ws_01/joint_states
```

**Pass:** within 1 Hz of what the workstation reported, jitter under 1 ms.
**Note:** the topic is namespaced. `/joint_states` unprefixed means you are
reading a local publisher, not the workstation's — that is a fail, not a pass.

### 3.3 The Mac sees it, on Wi-Fi

Same command, Ethernet unplugged.

**Pass:** same rate, within 1 Hz. This is the line the whole migration is for:
AP multicast filtering is what broke the DDS path, and zenoh's TCP session to
the router is not subject to it.
**Fail:** works wired and not wireless means something is still using multicast.

### 3.4 The Jetson sees it

```bash
fm device ssh fm-rec-01 -- 'ros2 topic hz /fm_ws_01/joint_states'
```

**Pass:** within 1 Hz.

### 3.5 The sim-first loop runs on zenoh, on one host

The open question this gate exists to answer. In CI the loop job is pinned to
`dds-lan`: on the default it fails there with the stack up, `/joint_states`
advertised, and no sample reaching the first `ros2 topic echo --once` inside 20
seconds. Cyclone's participant ceiling on loopback was one cause and is fixed;
whatever remains is not understood, and a container with no bridge and no router
in it is the wrong place to chase it.

The workstation runs the same stack for real, so it is answered here.

```bash
fm device ssh fm-ws-01 -- 'cd $(fm machine show --json | jq -r .workspace)/fm_ros2 && ./scripts/ci/loop.sh'
```

**Pass:** the loop completes — an episode reaches the index, a manifest is
written, and at least one episode in it is usable.
**Fail:** `no /joint_states message within 20s`. Capture
`ros2 topic info /joint_states --verbose` from a second shell while the stack is
up and attach it to the pull request; the QoS on both ends is the first thing to
read. Do not merge — with this red, a workstation on zenoh cannot record.

Once green, drop the `FM_TRANSPORT=dds-lan` pin on the loop job in
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

**Pass:** `verify` reports at least one episode. A manifest describing zero
episodes is a fail — that is a loop that ran and processed nothing.

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
ssh rune 'curl -s http://127.0.0.1:8000/@/local/router | jq ".[0].value.sessions | length"'
```

**Pass:** the session count returns to its pre-cycle value within two minutes,
with no manual step.

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
   `FM_TRANSPORT=dds-lan` documented as unsupported. Drop the pin it still holds
   on the loop CI job (section 3.5).
2. Take the pull requests out of draft.
3. Merge in order: `.github` → `fm-comms` → `fm-docker` → `fm-ros2` →
   `.github-private`.
4. Cut the real tag set.
5. Move ADR 0004 from Proposed to Accepted, recording Rune as the router host.

Paste the completed checklist into the fm-comms pull request. A gate whose
results live only in someone's terminal did not happen.
