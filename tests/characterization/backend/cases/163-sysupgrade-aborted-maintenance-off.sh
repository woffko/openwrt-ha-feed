# A sysupgrade that did not go on after the hand-over (role sysupgrade),
# then "maintenance off" with nothing of the service left in procd. The
# states recorded say STOP, so the 'master' uplink stays down until
# keepalived reports again; the mark of the hand-over makes the command
# start the service (keepalived and the monitor back), and goes.
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
case_after() {
	ha_role_record main MASTER
	ifstatus_fixture wan true false true
	/usr/lib/ha-cluster/role sysupgrade
	echo "== after the hand-over: recorded $(cut -d' ' -f1 "$HA_ROLE_DIR/instance.main"), mark: $([ -e "$HA_ROLE_DIR/sysupgrade" ] && echo yes || echo no)"
	ifstatus_fixture wan false false false
	: > "$CHAR_LOG"
	_char_killed=1
	maintenance off > /tmp/maint.out 2>&1
	echo "== off: rc=$?"
	grep -E '^Maintenance|^Not' /tmp/maint.out
	echo "== mode: $(ha_maintenance_mode), hold: $([ -e "$HA_ROLE_DIR/hold" ] && echo yes || echo no), mark: $([ -e "$HA_ROLE_DIR/sysupgrade" ] && echo yes || echo no)"
	echo "== started again: $(grep -c 'Starting HA cluster' "$CHAR_LOG")"
	echo "== netifd calls for wan:"
	grep 'network.interface.wan' "$CHAR_LOG" || echo "(none)"
	: > "$CHAR_LOG"
}
