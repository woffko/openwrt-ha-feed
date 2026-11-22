# As 106 (a kea-dhcp4 config that does not listen on br-lan), with
# luci-app-kea's setup there: the config is the user's own, the setup leaves
# it alone, and the refusal says so
. "$CHAR/backend/kea-switch.inc"
sed -i 's/"br-lan" \]/"eth9" ]/' /etc/kea/kea-dhcp4.conf
export KEA_SETUP_BIN="$CHAR/stubs/kea-setup"
export FAKE_KEA_SETUP="$CHAR/backend/fixtures/kea-setup-own-config.json"
export FAKE_KEA_SETUP_RC=3
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
