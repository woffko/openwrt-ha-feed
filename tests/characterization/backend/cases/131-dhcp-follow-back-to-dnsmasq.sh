# As 113, then the other node switches back to dnsmasq: the pool of 'lan'
# gives out DHCPv4 again in the synced /etc/config/dhcp, and procd runs
# dhcp_changed (reload_config, after owsync took the file). The node
# follows back: what it turned on in Kea's settings is turned off again,
# and dnsmasq is the server
. "$CHAR/backend/kea-switch.inc"
uci set dhcp.lan.dhcpv4=disabled
uci set dhcp.lan.ha_cluster_dhcpv4=unset
STEP2=dhcp_changed
step2() {
	uci -q delete dhcp.lan.dhcpv4
	uci -q delete dhcp.lan.ha_cluster_dhcpv4
}
case_after() {
	kea_switch_after
	echo "== turned on by following: $(cat /etc/ha-cluster/kea-followed 2>/dev/null || echo '(none)')"
}
