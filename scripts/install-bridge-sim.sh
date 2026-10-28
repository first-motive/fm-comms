#!/usr/bin/env bash
#
# install-bridge-sim.sh — add the Jazzy sim bridge beside a workstation's own.
#
# A workstation's bridge runs in its host's distro, Humble, and a Humble bridge
# never discovers the nodes of a Jazzy sim run beside it. So a workstation that
# hosts sim runs takes a second bridge: zenoh/bridge-sim.json5, rendered with the
# card's namespace and node name zenoh_bridge_<namespace>_sim, written to
# /etc/fm-comms/bridge-sim.json5, and run by fm-zenoh-bridge-sim.service with
# ROS_DISTRO=jazzy. zenoh/bridge-sim.json5 says why the two can share a namespace.
#
# On a Mac this script installs no service. fm-sim's agent runs each run in an
# OrbStack container without host networking, so a bridge native to the Mac
# never sees the run's DDS graph. The agent runs the bridge in a container
# beside each run instead, and this script only renders its config to
# ~/.config/fm-comms/bridge-sim.json5 beside the Mac's cyclonedds.xml.
#
# On Linux everything else is install-bridge.sh's, unchanged — the pinned
# package, the env file, the Cyclone profile, restart-on-change. On a Mac only the
# env file and the Cyclone profile apply. Either way this script only names the
# variant and hands over. Read the render before installing it:
#     ./run.sh render bridge-sim
#     ./run.sh render bridge-sim-unit
#
# Runnable standalone or through the front door:
#     ./scripts/install-bridge-sim.sh [install|uninstall]
#     ./install.sh --role bridge-sim
#
# Env: FM_DRY_RUN, FM_YES (as install-bridge.sh), FM_SIM_ROS_DISTRO (default jazzy)

set -euo pipefail

FM_BRIDGE_VARIANT=sim exec bash "$(dirname "${BASH_SOURCE[0]}")/install-bridge.sh" "$@"
