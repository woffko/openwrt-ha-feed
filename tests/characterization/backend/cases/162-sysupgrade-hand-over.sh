# The quick hand-over of a sysupgrade (role sysupgrade, run by
# /lib/upgrade/ha-cluster.sh): the mark of maintenance until reboot and its
# result, the hold of the 'master' uplinks (wan down), keepalived and the
# monitor removed from procd. No reload of the service: rpcd kills a
# sysupgrade started from LuCI after 30 seconds.
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
case_after() {
	ha_role_record main MASTER
	ifstatus_fixture wan true false true
	: > "$CHAR_LOG"
	/usr/lib/ha-cluster/role sysupgrade
	echo "== rc=$? mode: $(ha_maintenance_mode), hold: $([ -e "$HA_ROLE_DIR/hold" ] && echo yes || echo no)"
	echo "== last: $(cut -d' ' -f3- "$HA_MAINTENANCE_LAST")"
	cat "$CHAR_LOG"
	: > "$CHAR_LOG"
}
