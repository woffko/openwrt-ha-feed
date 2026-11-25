# A maintenance command while another holds the maintenance lock: refused at
# once, nothing changed
export FAKE_KEEPALIVED="$CHAR/rpcd/fixtures/keepalived-fault-init.json"
case_after() {
	( flock -x 9; sleep 4 ) 9>>"$HA_MAINTENANCE_LOCK" &
	sleep 1
	echo "== running: $(ha_maintenance_running && echo yes || echo no)"
	maintenance temp force > /tmp/maint.out 2>&1
	echo "== temp force: rc=$? $(cat /tmp/maint.out)"
	echo "== mode: $(ha_maintenance_mode)"
	wait
	echo "== running after: $(ha_maintenance_running && echo yes || echo no)"
	: > "$CHAR_LOG"
}
