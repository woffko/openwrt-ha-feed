# A 'master' uplink for a PPPoE wan that comes up at boot (no auto): the
# start sets auto '0', keeps 'unset' in ha_cluster_auto, has netifd read
# the config again, and runs the uplink monitor
. "$CHAR/backend/uplinks.inc"
uplink_section wan wan master main
case_after() {
	show_network_auto
}
