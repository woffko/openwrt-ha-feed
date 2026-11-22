# dhcp_backend 'kea' while dnsmasq gives out DHCPv6 in the pool of 'lan'
# (its Router Advertisements, DHCPv6 not disabled): refused, ha-cluster
# switches DHCPv4 only
. "$CHAR/backend/kea-switch.inc"
uci set dhcp.lan.ra=server
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=kea; }
case_after() { kea_switch_after; }
