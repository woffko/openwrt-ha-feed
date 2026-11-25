# Uplinks in mode unmanaged, as LuCI lists every WAN interface: not checked
# (lan is allowed there, no vrrp_instance needed), not managed (no monitor),
# and an interface that had auto '0' from a 'master' uplink gets it back
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uci set network.wan.ha_cluster_auto=unset
uplink_section wan wan unmanaged main
uplink_section u_lan lan unmanaged
case_after() {
	show_network_auto
	echo "== uplinks managed: $(ha_uplinks | tr '\n' ' ')"
}
