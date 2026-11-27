#!/bin/sh
# SPDX-License-Identifier: MIT
# Run by procd as the owsync instance of ha-cluster while this node joins a
# working cluster (option sync_join of /etc/config/ha-cluster): takes the
# synced files from a peer, then becomes the owsync daemon. See
# ha_owsync_join_run in ha-cluster.sh. Installed as
# /usr/lib/ha-cluster/owsync-join.

HA_CLUSTER_LIB="${HA_CLUSTER_LIB:-/usr/lib/ha-cluster/ha-cluster.sh}"
. "$HA_CLUSTER_LIB"

ha_owsync_join_run
