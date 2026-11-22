# As 126, but what luci-app-kea's setup writes still does not listen on
# br-lan: the check after the setup refuses the switch, nothing else is
# changed, and dnsmasq stays
. "$CHAR/backend/kea-switch.inc"
cp "$CHAR/backend/fixtures/kea-dhcp4-sample.conf" /etc/kea/kea-dhcp4.conf
uci set ha-cluster.peer1.source_address=172.30.0.10
export KEA_SETUP_BIN="$CHAR/stubs/kea-setup"
export FAKE_KEA_SETUP="$CHAR/backend/fixtures/kea-setup-written.json"
export FAKE_KEA_SETUP_CONF="$CHAR/backend/fixtures/kea-dhcp4-eth9.conf"
rm -f /tmp/fake-kea-setup.log /tmp/fake-kea-leases.log
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=kea; }
case_after() {
	kea_switch_after
	echo "== setup calls"
	cat /tmp/fake-kea-setup.log 2>/dev/null || echo "(none)"
	echo "== Kea's interfaces: $(grep -o '"interfaces": \[[^]]*\]' /etc/kea/kea-dhcp4.conf)"
}
