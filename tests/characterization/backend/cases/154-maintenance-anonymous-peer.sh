# The peer as an anonymous section (config peer), as on the routers: it
# counts, and answers, so maintenance until reboot is entered without force
export FAKE_KEEPALIVED="$CHAR/rpcd/fixtures/keepalived-fault-init.json"
uci delete ha-cluster.peer1
uci add ha-cluster peer > /dev/null
uci set ha-cluster.@peer[-1].name=node2
uci set ha-cluster.@peer[-1].address=172.30.0.11
case_after() {
	maintenance temp > /tmp/maint.out 2>&1
	echo "== temp: rc=$?"
	grep -E '^Maintenance|^Refused' /tmp/maint.out
	echo "== mode: $(ha_maintenance_mode)"
	: > "$CHAR_LOG"
}
