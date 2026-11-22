# Automatic, Kea not set up here, and the pool of 'lan' switched off for
# Kea by another node (/etc/config/dhcp is synced): this node runs dnsmasq
# and leaves the pool alone
. "$CHAR/backend/kea-switch.inc"
uci set dhcp.lan.dhcpv4=disabled
uci set dhcp.lan.ha_cluster_dhcpv4=unset
case_after() { kea_switch_after; }
