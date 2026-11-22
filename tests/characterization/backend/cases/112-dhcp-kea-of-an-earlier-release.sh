# dhcp_backend 'kea' on a node that ran a release without switching: the
# user switched the pool off and set Kea up by hand. Nothing is switched,
# imported or started; the node notes that it runs Kea
. "$CHAR/backend/kea-switch.inc"
uci set ha-cluster.config.dhcp_backend=kea
uci set dhcp.lan.dhcpv4=disabled
case_after() { kea_switch_after; }
