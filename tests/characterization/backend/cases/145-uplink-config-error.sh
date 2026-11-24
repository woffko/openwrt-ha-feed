# As 144, but netifd stopped on an error of the interface's configuration:
# not tried again, said once
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
case_after() {
	ha_role_record main MASTER
	mkdir -p "$HA_ROLE_DIR"
	echo "up 100 100 0 120" > "$HA_ROLE_DIR/uplink.wan"
	ifstatus_fixture wan false false false OPTION_ERROR
	uplinks_round
	echo "up 100 100 1 120" > "$HA_ROLE_DIR/uplink.wan"
	uplinks_round
}
