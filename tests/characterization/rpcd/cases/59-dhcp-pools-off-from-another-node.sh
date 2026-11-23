# This node is set to dnsmasq (dhcp_backend 'dnsmasq') while the pool of
# 'lan' is switched off for Kea (another node switched): it does not follow
# an explicit setting, and the status is DEGRADED
. "$CHAR/backend/kea-switch.inc"
uci set ha-cluster.config.dhcp_backend=dnsmasq
uci set dhcp.lan.dhcpv4=disabled
uci set dhcp.lan.ha_cluster_dhcpv4=unset
