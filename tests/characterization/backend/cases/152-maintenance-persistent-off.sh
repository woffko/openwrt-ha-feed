# Maintenance kept across reboots (on): option maintenance in the config,
# the files 0 1 once the hand-over is done (the last candidate). Then off:
# the option and the files go, keepalived's config has no track_file
export FAKE_KEEPALIVED="$CHAR/rpcd/fixtures/keepalived-fault-init.json"
case_after() {
	maintenance on > /tmp/maint.out 2>&1
	echo "== on: rc=$?"
	grep -E '^Maintenance|^Refused' /tmp/maint.out
	echo "== mode: $(ha_maintenance_mode), option: $(uci -q get ha-cluster.config.maintenance)"
	echo "== fault $(cat "$HA_MAINTENANCE_FAULT") demote $(cat "$HA_MAINTENANCE_DEMOTE")"
	echo "== track_file lines: $(grep -c track_file "$KEEPALIVED_CONF")"
	maintenance off > /tmp/maint.out 2>&1
	echo "== off: rc=$?"
	grep -E '^Maintenance|^Not' /tmp/maint.out
	echo "== mode: $(ha_maintenance_mode), option: $(uci -q get ha-cluster.config.maintenance || echo none)"
	ls "$HA_CLUSTER_RUN_DIR" | grep maintenance || echo "(no maintenance file)"
	echo "== track_file lines: $(grep -c track_file "$KEEPALIVED_CONF")"
	: > "$CHAR_LOG"
}
