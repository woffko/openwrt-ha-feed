# As 104, with a luci-app-kea that hands leases over but says Kea does not
# run: the switch is made all the same, with a warning
. "$CHAR/backend/kea-switch.inc"
export FAKE_KEA_LEASES="$CHAR/backend/fixtures/kea-leases-not-running.json"
export FAKE_KEA_LEASES_RC=1
rm -f /tmp/fake-kea-leases.log
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=kea; }
case_after() {
	kea_switch_after
	echo "== leases calls"
	cat /tmp/fake-kea-leases.log 2>/dev/null || echo "(none)"
}
