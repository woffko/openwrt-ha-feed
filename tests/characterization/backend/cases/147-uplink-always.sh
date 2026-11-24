# A static wanb in mode always, with auto '0': brought up whatever the role,
# its auto left alone
. "$CHAR/backend/uplinks.inc"
uci set network.wanb.auto=0
uplink_section wanb wanb always
case_after() {
	show_network_auto
	ifstatus_fixture wanb false false false
	ha_role_record main BACKUP
	uplinks_round
}
