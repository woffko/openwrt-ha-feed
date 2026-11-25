# The service is stopped (the node stays: wan down, auto '0' kept), then
# disabled: the node leaves the cluster, and the interface gets its auto
# back and is brought up as that asks
. "$CHAR/backend/uplinks.inc"
uplink_section wan wan master main
case_after() {
	stop > /dev/null 2>&1
	: > "$CHAR_LOG"
	echo "== disable"
	disable
	cat "$CHAR_LOG"
	show_network_auto
	echo "== rc.d: $(ls /etc/rc.d | grep ha-cluster || echo none)"
}
