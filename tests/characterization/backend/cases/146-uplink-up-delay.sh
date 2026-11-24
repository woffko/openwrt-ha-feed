# up_delay 30: MASTER since a moment ago, the wan is not brought up yet
# (wait); 30 s later it is
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
uci set ha-cluster.wan.up_delay=30
case_after() {
	ifstatus_fixture wan false false false
	ha_role_record main MASTER
	config_load ha-cluster
	ha_uplinks_reconcile
	echo "== wake in $_ha_uplinks_wake s"
	uplinks_round
	echo "1030.00 2000.00" > /tmp/fake-proc/uptime
	uplinks_round
}
