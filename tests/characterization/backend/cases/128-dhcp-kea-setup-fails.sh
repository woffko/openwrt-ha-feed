# As 126, but luci-app-kea's setup fails (Kea refused what it built): nothing
# is changed, dnsmasq stays, and the status says why
. "$CHAR/backend/kea-switch.inc"
cp "$CHAR/backend/fixtures/kea-dhcp4-sample.conf" /etc/kea/kea-dhcp4.conf
export KEA_SETUP_BIN="$CHAR/stubs/kea-setup"
export FAKE_KEA_SETUP="$CHAR/backend/fixtures/kea-setup-failed.json"
export FAKE_KEA_SETUP_RC=1
rm -f /tmp/fake-kea-setup.log /tmp/fake-kea-leases.log
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=kea; }
case_after() {
	kea_switch_after
	echo "== setup calls"
	cat /tmp/fake-kea-setup.log 2>/dev/null || echo "(none)"
	echo "== leases calls"
	cat /tmp/fake-kea-leases.log 2>/dev/null || echo "(none)"
}
