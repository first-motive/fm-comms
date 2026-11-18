#!/usr/bin/env bash
#
# install-bridge-perception.sh — add the remote-perception bridge beside a
# workstation's own.
#
# A workstation that runs fm-skills-perception for a robot on the fabric reads
# the robot's cameras and frame tree under the robot's prefix and publishes its
# detections back there, which a namespaced bridge cannot do: it would nest
# every key under the workstation's own name. So it takes a third bridge:
# zenoh/bridge-perception.json5, rendered with no namespace under node name
# zenoh_bridge_<namespace>_perception, written to
# /etc/fm-comms/bridge-perception.json5, and run by
# fm-zenoh-bridge-perception.service with ROS_DISTRO=jazzy, the fm-skills
# image's distro.
#
# Everything else is install-bridge.sh's, unchanged — the pinned package, the
# env file, the Cyclone profile, restart-on-change. This script only names the
# variant and hands over. Its rules name one robot, the one this workstation
# runs perception for, given as FM_PERCEPTION_ROBOT (its machine name) and
# required. Read the render before installing it:
#     FM_PERCEPTION_ROBOT=fm-rob-02 ./run.sh render bridge-perception
#     ./run.sh render bridge-perception-unit
#
# Runnable standalone or through the front door:
#     FM_PERCEPTION_ROBOT=fm-rob-02 ./scripts/install-bridge-perception.sh [install|uninstall]
#     FM_PERCEPTION_ROBOT=fm-rob-02 ./install.sh --role bridge-perception
#
# Env: FM_PERCEPTION_ROBOT (required), FM_DRY_RUN, FM_YES (as install-bridge.sh),
# FM_PERCEPTION_ROS_DISTRO (default jazzy)

set -euo pipefail

FM_BRIDGE_VARIANT=perception exec bash "$(dirname "${BASH_SOURCE[0]}")/install-bridge.sh" "$@"
