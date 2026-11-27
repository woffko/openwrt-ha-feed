# keepalived's rpcd plugin removes the dump file, signals keepalived and
# reads the file at once, without waiting for keepalived to write it: now
# and then "ubus call keepalived dump" answers "{ }". The states are asked
# again (three times at most), and an answer that stays empty is "not
# known", not "no instance is MASTER": the look at Kea during a
# maintenance does nothing then.
case_after() {
	echo '{ }' > /tmp/empty.json
	master="$CHAR/rpcd/fixtures/keepalived-master.json"
	ask() { # title, fixtures in the order of the answers
		rm -f /tmp/fake-keepalived-calls
		export FAKE_KEEPALIVED="$2"
		echo "== $1"
		echo "   states: $(_ha_keepalived_states | tr '\n' ';')"
		echo "   asked $(cat /tmp/fake-keepalived-calls) time(s)"
	}
	ask "an answer with the instances" "$master"
	ask "an empty answer, then the instances" "/tmp/empty.json $master"
	ask "two empty answers, then the instances" "/tmp/empty.json /tmp/empty.json $master"
	ask "nothing but empty answers" "/tmp/empty.json"

	echo "== the look at Kea during a maintenance, keepalived not saying its states"
	ha_dhcp_backend_is_kea() { return 0; }
	ha_maintenance_kea_resume_bg() { echo "   resume called"; }
	_ha_kea_ha_state() { _hk_answered=1; _hk_ha=0; [ "$1" = dhcp4 ] || return 0; _hk_ha=1; _hk_state="hot-standby"; }
	ha_ensure_run_dir
	echo "temp 1" > "$HA_MAINTENANCE_TEMP"
	rm -f /tmp/fake-keepalived-calls
	ha_maintenance_kea_check
	echo "   (nothing above: Kea is left alone)"
	rm -f "$HA_MAINTENANCE_TEMP"
	export FAKE_KEEPALIVED="$master"
	rm -f /tmp/fake-keepalived-calls
	: > "$CHAR_LOG"
}
