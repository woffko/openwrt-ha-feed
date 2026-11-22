# This node runs dnsmasq while the pool of 'lan' is switched off for Kea
# (another node switched): DEGRADED
. "$CHAR/backend/kea-switch.inc"
uci set dhcp.lan.dhcpv4=disabled
uci set dhcp.lan.ha_cluster_dhcpv4=unset
