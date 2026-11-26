#!/bin/sh
# SPDX-License-Identifier: MIT
# ha-cluster's work at the VRRP state changes of this node: the uplinks
# (config uplink) that follow the role, and Kea when the peer goes during a
# maintenance. Installed as /usr/lib/ha-cluster/role.
#
#   role event       from /etc/hotplug.d/keepalived/10-ha-cluster-role, with
#                    keepalived's ACTION, TYPE and NAME: records the state of
#                    the instance, then brings the uplinks in line in the
#                    background
#   role reconcile   brings the uplinks in line with the states recorded,
#                    waiting for an up_delay that runs
#   role monitor     the service's instance: every few seconds the uplinks
#                    in line (netifd that stopped retrying, an interface
#                    brought up by hand on a node that is not MASTER), and
#                    every minute the states recorded checked against
#                    keepalived's own
#   role sysupgrade  from /lib/upgrade/ha-cluster.sh while /sbin/sysupgrade
#                    writes the backup of the settings, before it hands the
#                    image to procd: the hand-over of maintenance until
#                    reboot, done quickly (a few seconds; rpcd kills a
#                    sysupgrade run from LuCI after 30): the mark, Kea
#                    in-maintenance (four seconds for the partner), the
#                    'master' uplinks down (PADT), and keepalived and the
#                    monitor removed from procd, so that the peer is MASTER
#                    at once. A reboot or "maintenance off" ends it.

HA_CLUSTER_LIB="${HA_CLUSTER_LIB:-/usr/lib/ha-cluster/ha-cluster.sh}"
. "$HA_CLUSTER_LIB"

ha_log_init 2>/dev/null

# Usage: role_enabled
# The cluster is enabled and has something for this program to do
role_enabled() {
	config_load ha-cluster
	config_get_bool enabled config enabled 0
	[ "$enabled" -eq 1 ]
}

# Brings the uplinks in line, then again when an up_delay ends
role_reconcile() {
	local rounds=0

	while :; do
		config_load ha-cluster
		ha_role_locked ha_uplinks_reconcile_wake || return 0
		[ -s "$HA_ROLE_DIR/.wake" ] || return 0
		rounds=$((rounds + 1))
		[ "$rounds" -le 10 ] || return 0
		sleep "$(cat "$HA_ROLE_DIR/.wake")"
	done
}

# Usage: ha_uplinks_reconcile_wake
# ha_uplinks_reconcile, leaving in $HA_ROLE_DIR/.wake the seconds until the
# first up_delay that runs ends (the lock is held in a subshell)
ha_uplinks_reconcile_wake() {
	ha_uplinks_reconcile
	if [ "$_ha_uplinks_wake" -gt 0 ]; then
		echo "$_ha_uplinks_wake" > "$HA_ROLE_DIR/.wake"
	else
		rm -f "$HA_ROLE_DIR/.wake"
	fi
}


case "$1" in
	event)
		case "${ACTION:-}" in
			MASTER|BACKUP|FAULT) ;;
			*) exit 0 ;;
		esac
		[ -z "${TYPE:-}" ] || [ "$TYPE" = "INSTANCE" ] || exit 0
		role_enabled || exit 0
		ha_role_record "${NAME:-}" "$ACTION" || exit 0
		# The node in maintenance becomes MASTER: the peer is gone
		ha_maintenance_on_role "$NAME" "$ACTION"
		[ -n "$(ha_uplinks)" ] || exit 0
		"$0" reconcile </dev/null >/dev/null 2>&1 &
		;;
	reconcile)
		role_enabled || exit 0
		role_reconcile
		;;
	monitor)
		n=0
		while :; do
			if role_enabled && [ -n "$(ha_uplinks)" ]; then
				# The states recorded against keepalived's own
				[ "$n" -eq 0 ] && ha_role_sync
				ha_role_locked ha_uplinks_reconcile
			fi
			n=$(((n + 1) % 12))
			sleep "$HA_ROLE_MONITOR_INTERVAL"
		done
		;;
	sysupgrade)
		role_enabled || exit 0
		pgrep keepalived >/dev/null 2>&1 || exit 0
		ha_ensure_run_dir || exit 0
		# The node says it is in maintenance if the upgrade stops after this
		echo "temp $(date +%s)" > "$HA_MAINTENANCE_TEMP"
		echo "$(date '+%Y-%m-%d %H:%M:%S') sysupgrade: roles handed over (maintenance until reboot)" > "$HA_MAINTENANCE_LAST"
		ha_log_warning "sysupgrade: this node hands its roles over"
		ha_dhcp_backend_is_kea && HA_KEA_ENTER_WAIT=4 ha_kea_maintenance enter
		mkdir -p "$HA_ROLE_DIR" && : > "$HA_ROLE_DIR/hold"
		ha_role_locked ha_uplinks_reconcile
		ubus call service delete '{"name":"ha-cluster","instance":"monitor"}' >/dev/null 2>&1
		ubus call service delete '{"name":"ha-cluster","instance":"keepalived"}' >/dev/null 2>&1
		# keepalived reports nothing when it stops. The states recorded say
		# STOP, so that "maintenance off" after an upgrade that did not go
		# on brings no 'master' uplink up for a MASTER that is gone, and the
		# mark tells that command to start the service again (keepalived
		# and the monitor are out of procd). The IPv6 guard closed, as at a
		# stop of the service.
		for f in "$HA_ROLE_DIR"/instance.*; do
			[ -f "$f" ] && ha_role_record "${f##*/instance.}" STOP
		done
		: > "$HA_ROLE_DIR/sysupgrade"
		ha_close_ipv6_guard
		ha_log_info "sysupgrade: roles handed over"
		;;
	*)
		echo "Usage: $0 event|reconcile|monitor|sysupgrade" >&2
		exit 1
		;;
esac
exit 0
