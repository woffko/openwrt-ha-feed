# Maintenance until reboot, forced: keepalived's config follows the two
# files, every instance in FAULT (1 0), the mark in the run directory
export FAKE_KEEPALIVED="$CHAR/rpcd/fixtures/keepalived-fault-init.json"
case_after() {
	echo "== maintenance temp force"
	maintenance temp force > /tmp/maint.out 2>&1
	echo "rc=$?"
	grep -E '^Maintenance|^Refused|^Already' /tmp/maint.out
	echo "== mode: $(ha_maintenance_mode)"
	echo "== fault $(cat "$HA_MAINTENANCE_FAULT") demote $(cat "$HA_MAINTENANCE_DEMOTE")"
	echo "== keepalived.conf, maintenance"
	grep -E 'track_file|ha_cluster_(fault|demote)|weight|maintenance' "$KEEPALIVED_CONF"
	echo "== log"
	grep -E 'aintenance|hand' "$CHAR_LOG"
	: > "$CHAR_LOG"
}
