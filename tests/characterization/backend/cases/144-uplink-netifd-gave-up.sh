# MASTER, the wan was brought up long ago, and netifd stopped trying after
# an authentication failure (authfail): tried again, attempt 1. A round
# within retry seconds does nothing more.
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
case_after() {
	ha_role_record main MASTER
	mkdir -p "$HA_ROLE_DIR"
	echo "up 100 100 0 120" > "$HA_ROLE_DIR/uplink.wan"
	ifstatus_fixture wan false false false AUTH_TOPEER_FAILED
	uplinks_round
	uplinks_round
}
