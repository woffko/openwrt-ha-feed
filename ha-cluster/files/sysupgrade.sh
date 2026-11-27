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
# acts, with the quick hand-over of "/usr/lib/ha-cluster/role sysupgrade"
# (a few seconds). Quick because LuCI runs sysupgrade through rpcd, which
# kills it after 30 seconds (option timeout of /etc/config/rpcd) and would
# leave a node that handed its roles over and never upgraded. LuCI's web
# server stops first: the flash page takes the device as rebooted as soon
# as a page of it answers again, and would go to the overview. Only a web
# server that runs is stopped, and it starts
# again after 150 seconds if the upgrade does not go on: a timer does it
# while the mark this hand-over left (uhttpd-restore in the run directory)
# is still its own. A later sysupgrade writes another mark, so the timer of
# an attempt that failed cannot start the server under the next one, and
# "maintenance" takes the mark away and starts the server at once.
# Not for a backup alone (-b), a list (-l) or a test (-T). An upgrade that
# writes no backup gets no hand-over: without the settings (-n), or with
# the settings of an archive (-f): hand the roles over first with
# "maintenance temp". The maintenance ends with the reboot; an upgrade that
# fails after this leaves it on, as the status says, until "maintenance
# off" or a reboot. Bounded by its own timer (15 s, then TERM, then KILL):
# BusyBox has no timeout, and the package does not depend on coreutils.

# Seconds until LuCI's web server is started again, and the mark of the timer
ha_cluster_sysupgrade_uhttpd_back=150
ha_cluster_sysupgrade_uhttpd_mark=/var/run/ha-cluster/uhttpd-restore

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
	# Only a web server that runs: one the user has stopped or disabled is
	# not started by the timer or by "maintenance" afterwards. One that an
	# earlier attempt stopped (its mark still stands) counts as running:
	# this attempt takes the mark over, or that attempt's timer would
	# start the server under this one.
	if [ -x /etc/init.d/uhttpd ] && { pgrep uhttpd >/dev/null 2>&1 ||
	   [ -e "$ha_cluster_sysupgrade_uhttpd_mark" ]; }; then
		/etc/init.d/uhttpd stop >/dev/null 2>&1
		# Back after a while if the upgrade does not go on: the second
		# stage ends every process before it writes the image. Without a
		# mark (the run directory cannot be made) the timer starts the
		# server in any case.
		ha_cluster_sysupgrade_token="$$.$(date +%s)"
		[ -L "${ha_cluster_sysupgrade_uhttpd_mark%/*}" ] && rm -f "${ha_cluster_sysupgrade_uhttpd_mark%/*}"
		mkdir -m 0700 -p "${ha_cluster_sysupgrade_uhttpd_mark%/*}" 2>/dev/null
		[ -d "${ha_cluster_sysupgrade_uhttpd_mark%/*}" ] &&
			echo "$ha_cluster_sysupgrade_token" 2>/dev/null > "$ha_cluster_sysupgrade_uhttpd_mark" ||
			ha_cluster_sysupgrade_token=""
		ha_cluster_sysupgrade_timer='sleep "$1"
if [ -n "$3" ]; then
	[ "$(cat "$2" 2>/dev/null)" = "$3" ] || exit 0
	rm -f "$2"
fi
/etc/init.d/uhttpd start'
		if command -v setsid >/dev/null 2>&1; then
			setsid sh -c "$ha_cluster_sysupgrade_timer" sh "$ha_cluster_sysupgrade_uhttpd_back" \
				"$ha_cluster_sysupgrade_uhttpd_mark" "$ha_cluster_sysupgrade_token" </dev/null >/dev/null 2>&1 &
		else
			sh -c "$ha_cluster_sysupgrade_timer" sh "$ha_cluster_sysupgrade_uhttpd_back" \
				"$ha_cluster_sysupgrade_uhttpd_mark" "$ha_cluster_sysupgrade_token" </dev/null >/dev/null 2>&1 &
		fi
	fi
	/usr/lib/ha-cluster/role sysupgrade </dev/null >/dev/null 2>&1 &
	ha_cluster_sysupgrade_pid=$!
	ha_cluster_sysupgrade_waited=0
	while kill -0 "$ha_cluster_sysupgrade_pid" 2>/dev/null; do
		if [ "$ha_cluster_sysupgrade_waited" -ge 15 ]; then
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
