# The hook of a sysupgrade (/lib/upgrade/ha-cluster.sh) stops LuCI's web
# server and leaves a timer that starts it again if the upgrade does not go
# on. The timer acts only while the mark of its own hand-over stands: the
# timer of an attempt that failed starts nothing under a later attempt, and
# "maintenance off" takes the mark away and starts the server at once.
# "role sysupgrade" takes the lock of the maintenance commands and goes on
# without it when one of them holds it too long.
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main

# The hook as /sbin/sysupgrade reads it: $1 = seconds of the timer
hook_run() {
	cat > /tmp/sysupgrade <<-'EOS'
		append() { :; }
		. /char-sysupgrade-hook
		ha_cluster_sysupgrade_uhttpd_back="$1"
		CONF_BACKUP="" CONF_BACKUP_LIST="" TEST="" IMAGE=/tmp/image.bin
		ha_cluster_sysupgrade_hand_over
	EOS
	sh /tmp/sysupgrade "$1"
}
web_calls() { grep -c "^uhttpd $1\$" "$CHAR_LOG"; }
mark() { [ -e "$HA_UHTTPD_RESTORE" ] && echo yes || echo no; }

case_after() {
	printf '#!/bin/sh\necho "uhttpd $*" >> "$CHAR_LOG"\n' > /etc/init.d/uhttpd
	chmod +x /etc/init.d/uhttpd
	ha_role_record main MASTER
	ifstatus_fixture wan true false true
	: > "$CHAR_LOG"

	# A first attempt (timer 6 s) fails, a second follows (timer 1 s)
	hook_run 6
	first="$(cat "$HA_UHTTPD_RESTORE")"
	echo "== first attempt: stopped $(web_calls stop), mark: $(mark)"
	sleep 1
	hook_run 1
	[ "$(cat "$HA_UHTTPD_RESTORE")" != "$first" ] && echo "== second attempt: stopped $(web_calls stop), another mark"
	sleep 3
	echo "== the timer of the second: started $(web_calls start), mark: $(mark)"
	sleep 4
	echo "== after the timer of the first: started $(web_calls start)"

	# A third attempt fails; "maintenance off" before its timer
	: > "$CHAR_LOG"
	hook_run 60
	echo "== third attempt: stopped $(web_calls stop), mark: $(mark)"
	_char_killed=1
	maintenance off > /tmp/maint.out 2>&1
	echo "== off: rc=$?, started $(web_calls start), mark: $(mark)"

	# A maintenance command holds its lock for longer than the wait
	: > "$CHAR_LOG"
	(
		flock -x 7
		sleep 4
	) 7>>"$HA_MAINTENANCE_LOCK" &
	sleep 1
	HA_SYSUPGRADE_LOCK_WAIT=1 /usr/lib/ha-cluster/role sysupgrade
	echo "== under a held lock: rc=$?, hold: $([ -e "$HA_ROLE_DIR/hold" ] && echo yes || echo no)"
	grep -o 'sysupgrade: a maintenance command still runs.*' "$CHAR_LOG"
	wait
	: > "$CHAR_LOG"
}
