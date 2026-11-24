# The node is BACKUP and the wan was down; someone brings it up by hand
# (LuCI's Connect, ifup): down again, with a warning
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
case_after() {
	ifstatus_fixture wan false false false USER_REQUEST
	ha_role_record main BACKUP
	uplinks_round
	ifstatus_fixture wan false true true
	uplinks_round
}
