# The interface has auto '0' already, as on routers with a hand-written
# keepalived hook: kept in ha_cluster_auto as it is, netifd not asked to
# read the config again
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
case_after() {
	show_network_auto
}
