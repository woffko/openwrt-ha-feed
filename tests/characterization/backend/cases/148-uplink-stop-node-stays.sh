# The service stops on a node that stays in the cluster: the 'master'
# uplink goes down (the session closed before the peer dials), the states
# recorded become STOP
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
case_before_start() {
	ha_role_record main MASTER
}
STEP2=stop
case_after() {
	echo "== recorded: $(cat "$HA_ROLE_DIR/instance.main" 2>/dev/null)"
	show_network_auto
}
