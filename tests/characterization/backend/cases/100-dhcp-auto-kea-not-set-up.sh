# dhcp_backend not set (automatic), Kea installed but its DHCPv4 server off
# in /etc/config/kea: dnsmasq stays, nothing is imported or switched, and
# the node notes that it runs dnsmasq
. "$CHAR/backend/kea-switch.inc"
case_after() { kea_switch_after; }
