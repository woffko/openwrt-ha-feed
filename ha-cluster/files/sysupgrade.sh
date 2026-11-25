# SPDX-License-Identifier: MIT
# ha-cluster, installed as /lib/upgrade/ha-cluster.sh: hands this node's
# roles over before a sysupgrade, so that the peer serves at once and the
# sessions of the 'master' uplinks are closed (PADT) before it dials.
#
# It must happen while the services still run. procd stops them all with a
# signal (service_stop_all) as soon as /sbin/sysupgrade hands it the image,
# before the second stage starts: netifd and pppd then go without a PADT,
# and the provider holds the session. /sbin/sysupgrade reads every
# /lib/upgrade/*.sh, checks the image, then writes the backup of the
# settings and runs the sysupgrade_init_conffiles hooks: that is where this
# acts, as "/etc/init.d/ha-cluster maintenance temp force", bounded in time.
# Not for a backup alone (-b), a list (-l) or a test (-T). An upgrade that
# writes no backup gets no hand-over: without the settings (-n), or with
# the settings of an archive (-f): hand the roles over first with
# "maintenance temp". The maintenance ends with the reboot; an upgrade that
# fails after this leaves it on, as the status says, until "maintenance
# off" or a reboot. Bounded by its own timer (40 s, then TERM, then KILL):
# BusyBox has no timeout, and the package does not depend on coreutils.

ha_cluster_sysupgrade_hand_over() {
	case "$0" in
		*/sysupgrade) ;;
		*) return 0 ;;
	esac
	[ -z "$CONF_BACKUP" ] && [ "$CONF_BACKUP_LIST" != "1" ] && [ "$TEST" != "1" ] && [ -n "$IMAGE" ] ||
		return 0
	[ -x /etc/init.d/ha-cluster ] && pgrep keepalived >/dev/null 2>&1 || return 0
	[ "$(uci -q get ha-cluster.config.enabled)" = "1" ] || return 0
	command -v v >/dev/null 2>&1 && v "ha-cluster: handing this node's roles over (maintenance until reboot)"
	/etc/init.d/ha-cluster maintenance temp force </dev/null >/dev/null 2>&1 &
	ha_cluster_sysupgrade_pid=$!
	ha_cluster_sysupgrade_waited=0
	while kill -0 "$ha_cluster_sysupgrade_pid" 2>/dev/null; do
		if [ "$ha_cluster_sysupgrade_waited" -ge 40 ]; then
			command -v v >/dev/null 2>&1 && v "ha-cluster: the hand-over takes too long, going on"
			kill -TERM "$ha_cluster_sysupgrade_pid" 2>/dev/null
			sleep 2
			kill -KILL "$ha_cluster_sysupgrade_pid" 2>/dev/null
			break
		fi
		sleep 1
		ha_cluster_sysupgrade_waited=$((ha_cluster_sysupgrade_waited + 1))
	done
	wait "$ha_cluster_sysupgrade_pid" 2>/dev/null
	return 0
}

append sysupgrade_init_conffiles ha_cluster_sysupgrade_hand_over
