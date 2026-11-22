# A node on dnsmasq set to dhcp_backend 'kea' while Kea's DHCPv4 config is
# still the sample of the Kea package: luci-app-kea's setup is given the
# nodes of the cluster (with the DHCP interfaces and their VIPs) and writes
# the config, what it could not set up is logged, the switch goes on as
# usual, and dnsmasq's leases are handed to the running Kea
. "$CHAR/backend/kea-switch.inc"
cp "$CHAR/backend/fixtures/kea-dhcp4-sample.conf" /etc/kea/kea-dhcp4.conf
uci set ha-cluster.peer1.source_address=172.30.0.10
export KEA_SETUP_BIN="$CHAR/stubs/kea-setup"
export FAKE_KEA_SETUP="$CHAR/backend/fixtures/kea-setup-written.json"
export FAKE_KEA_SETUP_CONF="$CHAR/backend/fixtures/kea-dhcp4-lan.conf"
export FAKE_KEA_LEASES="$CHAR/backend/fixtures/kea-leases-added.json"
export FAKE_KEA_LEASES_RC=0
rm -f /tmp/fake-kea-setup.log /tmp/fake-kea-setup.in /tmp/fake-kea-leases.log
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=kea; }
case_after() {
	kea_switch_after
	echo "== setup calls"
	cat /tmp/fake-kea-setup.log 2>/dev/null || echo "(none)"
	echo "== given to the setup"
	cat /tmp/fake-kea-setup.in 2>/dev/null
	echo
	echo "== leases calls"
	cat /tmp/fake-kea-leases.log 2>/dev/null || echo "(none)"
}
