# The user has staged dhcpv4 'disabled' for the pool of 'lan' and not
# applied it, when the node switches to Kea: the switch goes by the
# committed file, which still gives out DHCPv4, switches the pool off there
# (noting that it had no dhcpv4) and leaves the user's change staged
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
case_before_start() {
	uci set dhcp.lan.dhcpv4=disabled
}
case_after() {
	echo "== pool dhcp.lan in the config file"
	grep -E "dhcpv4|ha_cluster" /etc/config/dhcp || echo "(no dhcpv4 options)"
	echo "== staged by the user"
	uci changes dhcp
}
