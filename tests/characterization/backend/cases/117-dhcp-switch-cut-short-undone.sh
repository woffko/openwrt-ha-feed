# A switch to Kea cut short (state 'switching', the pool already off) on a
# node where Kea is no longer asked for: the pool gets its DHCPv4 back at
# the next start, and the node runs dnsmasq
. "$CHAR/backend/kea-switch.inc"
uci set dhcp.lan.dhcpv4=disabled
uci set dhcp.lan.ha_cluster_dhcpv4=unset
mkdir -p /etc/ha-cluster
echo switching > /etc/ha-cluster/dhcp-backend
case_after() { kea_switch_after; }
