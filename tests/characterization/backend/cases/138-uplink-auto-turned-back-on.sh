# Someone set the interface to come up at boot again (LuCI): the start sets
# auto '0' again and says so; the value kept stays the first one
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=1
uci set network.wan.ha_cluster_auto=unset
uplink_section wan wan master main
case_after() {
	show_network_auto
}
