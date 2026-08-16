# Remote Access

How someone outside the office watches a rig and pulls episodes: a tailnet
account, one ACL grant, one endpoint in a config file. No VPN concentrator, no
port forward, no public router.

The whole grant is **TCP 7447 on the router, and nothing else**. A contractor
never reaches a rig directly — the router is the only host they can open a socket
to, and the bridges decide what crosses it.

```
contractor  ──tailnet──▶  workstation:7447 (zenohd)  ◀──tailnet──  rig bridges
   client mode                  the only                 client mode
                            reachable host
```

## Before You Start

You need, on the office side:

- Tailscale admin on the tailnet, to invite a user and edit the ACL.
- The router already running: `systemctl status fm-zenohd` on the workstation.
- The rigs already bridged: `systemctl status fm-zenoh-bridge` on each.

And from the contractor:

- The email address to invite.
- Which rigs they need, and whether they need episodes as well as live topics.

## 1. Invite Them To The Tailnet

Invite the contractor as a regular user, not an admin. Tag the invite so the ACL
below can name them as a group rather than an address:

```bash
# From the Tailscale admin console: Users -> Invite external users.
# Then add them to the contractors group in the ACL (step 2).
```

Have them install Tailscale and confirm they can see the tailnet before you touch
the ACL — an access problem is much easier to read when only one thing is new.

## 2. Grant The Router Port, And Only That

The router carries a tag so the grant names a role rather than a machine. On the
workstation, once:

```bash
sudo tailscale up --advertise-tags=tag:fm-router
```

Before you run that, search the policy file for `tag:fm-router`. Advertising a tag
applies **every** existing rule that mentions it to this machine, so a stale rule
granting, say, SSH to that tag would take effect here the moment the tag lands.
The verification below catches it, but reading first is cheaper than debugging.

Then in the tailnet policy file:

```jsonc
{
  "tagOwners": {
    "tag:fm-router": ["autogroup:admin"],
  },
  "groups": {
    "group:fm-contractors": ["contractor@example.com"],
  },
  "grants": [
    {
      // The entire external surface: one port on one tagged host. A contractor
      // cannot reach a rig, the processor, or SSH on anything.
      "src": ["group:fm-contractors"],
      "dst": ["tag:fm-router"],
      "ip": ["tcp:7447"],
    },
  ],
}
```

On a tailnet still using the older `acls` block, the same grant reads:

```jsonc
{
  "acls": [
    {
      "action": "accept",
      "src": ["group:fm-contractors"],
      "dst": ["tag:fm-router:7447"],
    },
  ],
}
```

Check it from the contractor's machine before going further. This must succeed,
and everything else must fail:

```bash
tailscale status | grep fm-router          # the router is visible
nc -vz <workstation>.<tailnet>.ts.net 7447 # succeeds
nc -vz <workstation>.<tailnet>.ts.net 22   # must be refused
nc -vz <rig>.<tailnet>.ts.net 7447         # must be refused
```

If the last two succeed, the grant is too wide. Fix it before sharing anything
else — a working setup with a wrong ACL looks identical to a correct one.

## 3. Point Their Client At The Router

The contractor installs the client tools:

```bash
git clone https://github.com/first-motive/fm-comms.git
cd fm-comms
./install.sh --role client
```

They need one value from you — the router endpoint:

```
tcp/<workstation>.<tailnet>.ts.net:7447
```

Use the **tailnet** name, never the office LAN address. The LAN address is
unroutable for them, and it stops working for everyone the moment the workstation
moves.

The desktop app takes the same endpoint as a `zenoh://` rig URL in Settings.

## 4. Smoke Test The Session

Live topics from a rig, at the rig's namespace. That namespace is the rig's
machine name with its hyphens turned into underscores — `fm-rec-01` publishes
under `fm_rec_01` — so `./run.sh render show` on the rig tells you what to
subscribe to:

```bash
# Joint states from fm-rec-01 — should tick steadily.
z_sub -e tcp/<workstation>.<tailnet>.ts.net:7447 -k 'fm_rec_01/joint_states'

# What that rig is publishing at all. Nothing back means the bridge is down, or
# the topic is not on the rig's allowlist.
z_sub -e tcp/<workstation>.<tailnet>.ts.net:7447 -k 'fm_rec_01/**'
```

Episodes from the processor:

```bash
E=tcp/<workstation>.<tailnet>.ts.net:7447

# The index: every recorded episode, newest first.
z_get -e "$E" -s 'fm/episodes/index'

# One episode's metadata.
z_get -e "$E" -s 'fm/episodes/<episode-id>/meta'

# The MCAP itself. Large — see the size limit below.
z_get -e "$E" -s 'fm/episodes/<episode-id>/mcap' > episode.mcap
```

## What A Contractor Cannot Do

Worth stating plainly, because the tailnet makes it feel like a flat network:

- **Reach any host but the router.** The ACL grants one port on one tag.
- **See a topic a bridge did not allow.** Each rig's
  `zenoh/bridge-<profile>.json5` is an allowlist; a topic absent from it never
  leaves the rig, whatever a caller subscribes to.
- **Command a robot arm by accident.** The robot bridge accepts Servo jog
  commands, which apply the rig's own limits and collision checks, and it denies
  raw `joint_trajectory` outright.
- **Fetch an oversized episode.** A query is one request and one reply, so an
  MCAP over `FM_EPISODES_MAX_BYTES` is refused with its size rather than stalling
  the router for everyone. Ship those by rsync.

There is no per-user authorisation inside Zenoh: anyone who reaches the router
sees everything the bridges publish. The tailnet ACL is the access boundary, which
is why step 2 is worth verifying rather than assuming. mTLS and per-key
permissions were deliberately deferred — revisit them the first time someone
outside the tailnet needs in.

## When Something Does Not Work

| Symptom | Where to look |
| --- | --- |
| `nc` to 7447 refused | The ACL grant, then `systemctl status fm-zenohd` |
| Connects, no samples | `journalctl -u fm-zenoh-bridge -f` on the rig |
| Some topics, not others | That rig's `allow` list in `zenoh/bridge-<profile>.json5` |
| Samples arrive slowly | `pub_max_frequencies` in the same file — rates are capped on purpose |
| Episode index empty | `./run.sh render show` on the processor for the recordings path, and whether rsync has landed anything |
| Episode fetch refused | The error reply carries the reason; usually the size limit |

## Revoking Access

Remove them from `group:fm-contractors` in the policy file. That drops the grant
immediately — no rig or router change, and no restart. Removing the user from the
tailnet is the belt-and-braces version.
