# From persistent maintenance to maintenance until reboot while the peer
# does not answer: refused, as entering is (the node is still a candidate
# in persistent maintenance). With force it goes.
export FAKE_KEEPALIVED="$CHAR/rpcd/fixtures/keepalived-fault-init.json"
case_after() {
	maintenance on > /tmp/maint.out 2>&1
	echo "== on: rc=$? $(tail -n 1 /tmp/maint.out)"
	export FAKE_ONLINE=""
	maintenance temp > /tmp/maint.out 2>&1
	echo "== temp: rc=$? $(tail -n 1 /tmp/maint.out)"
	echo "== mode: $(ha_maintenance_mode)"
	maintenance temp force > /tmp/maint.out 2>&1
	echo "== temp force: rc=$? $(tail -n 1 /tmp/maint.out)"
	echo "== mode: $(ha_maintenance_mode)"
	echo "== last: $(cut -d' ' -f3- "$HA_MAINTENANCE_LAST")"
	: > "$CHAR_LOG"
}
