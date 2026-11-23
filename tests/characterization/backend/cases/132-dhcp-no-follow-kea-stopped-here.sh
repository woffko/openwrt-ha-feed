# As 113, but Kea was stopped on this node on purpose (from luci-app-kea):
# the node does not follow, runs dnsmasq and leaves the pool alone
. "$CHAR/backend/kea-switch.inc"
uci set dhcp.lan.dhcpv4=disabled
uci set dhcp.lan.ha_cluster_dhcpv4=unset
case_before_start() {
	mkdir -p /var/run/ha-cluster
	: > /var/run/ha-cluster/kea-stopped
}
case_after() { kea_switch_after; }
