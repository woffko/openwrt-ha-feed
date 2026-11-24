# The uplink section went: the interface gets its auto back (none), netifd
# reads the config again, and the interface is brought up as its auto asks
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uci set network.wan.ha_cluster_auto=unset
case_after() {
	show_network_auto
}
