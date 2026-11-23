# As 113, but kea-dhcp4 is not installed on this node: it cannot follow,
# runs dnsmasq and leaves the pool alone
. "$CHAR/backend/kea-switch.inc"
rm -f /usr/sbin/kea-dhcp4
uci set dhcp.lan.dhcpv4=disabled
uci set dhcp.lan.ha_cluster_dhcpv4=unset
case_after() { kea_switch_after; }
