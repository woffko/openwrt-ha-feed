#!/bin/sh
# SPDX-License-Identifier: MIT
# Run by owsync (on_change) after a sync session wrote or removed files of
# /etc/config that a peer sent. Applies them as LuCI's apply does: procd's
# reload_config reloads each service whose config changed (dnsmasq for
# dhcp, the firewall for firewall), and ha-cluster's trigger on dhcp has
# the node follow a switch of the DHCP server made on the other node.
#
# Sessions come in bursts: one run at a time, after a short pause, and one
# more when another session changed files meanwhile.

# In ha-cluster's run directory (0700, root's), not in /var/lock, where any
# local process could hold the lock or remove the mark
RUN_DIR="${HA_CLUSTER_RUN_DIR:-/var/run/ha-cluster}"
LOCK="${HA_OWSYNC_CHANGED_LOCK:-$RUN_DIR/owsync-changed.lock}"
PENDING="${HA_OWSYNC_CHANGED_PENDING:-$RUN_DIR/owsync-changed.pending}"
RELOAD_CONFIG="${HA_RELOAD_CONFIG_BIN:-/sbin/reload_config}"
SETTLE="${HA_OWSYNC_SETTLE:-2}"

(umask 077; mkdir -p "${LOCK%/*}") 2>/dev/null
: > "$PENDING" || exit 0
exec 9>"$LOCK" || exit 0
while :; do
	# The run that holds the lock sees the mark
	flock -n -x 9 2>/dev/null || exit 0
	while [ -e "$PENDING" ]; do
		# Sessions during the pause are taken by this run; those during
		# reload_config by the next one
		sleep "$SETTLE"
		rm -f "$PENDING"
		if "$RELOAD_CONFIG" >/dev/null 2>&1; then
			logger -t ha-cluster -p daemon.info "Config received from a peer: services reloaded where their config changed"
		else
			logger -t ha-cluster -p daemon.warn "Config received from a peer, but reload_config failed: its services run the config they had"
		fi
	done
	flock -u 9
	# A session that came between the last look and the unlock
	[ -e "$PENDING" ] || exit 0
done
