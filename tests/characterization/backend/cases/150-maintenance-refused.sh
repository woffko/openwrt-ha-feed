# Maintenance until reboot while the peer does not answer: refused, nothing
# changed. With force it is entered.
export FAKE_ONLINE=""
export FAKE_KEEPALIVED="$CHAR/rpcd/fixtures/keepalived-fault-init.json"
case_after() {
	echo "== maintenance temp"
	maintenance temp
	echo "rc=$?"
	echo "== mode: $(ha_maintenance_mode)"
	ls "$HA_CLUSTER_RUN_DIR" | grep maintenance || echo "(no maintenance file)"
}
