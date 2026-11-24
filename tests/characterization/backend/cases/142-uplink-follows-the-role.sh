# keepalived reports MASTER for main: the wan, down, is brought up. Then
# BACKUP: the wan, up, goes down (PADT)
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
case_after() {
	ifstatus_fixture wan false false false USER_REQUEST
	ha_role_record main MASTER
	uplinks_round
	ifstatus_fixture wan true false true
	ha_role_record main BACKUP
	uplinks_round
}
