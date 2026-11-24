# HA is disabled and the service stops: the node leaves the cluster, the
# interface gets its auto back and is brought up as that asks
. "$CHAR/backend/uplinks.inc"
uplink_section wan wan master main
STEP2=stop
step2() {
	uci set ha-cluster.config.enabled=0
}
case_after() {
	show_network_auto
}
