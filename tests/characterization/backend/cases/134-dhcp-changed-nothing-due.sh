# /etc/config/dhcp changes on a node on dnsmasq where nothing is to be
# switched (a lease time): dhcp_changed leaves the cluster alone, no reload
. "$CHAR/backend/kea-switch.inc"
STEP2=dhcp_changed
step2() { uci set dhcp.lan.leasetime=1h; }
case_after() { kea_switch_after; }
