# A node on dnsmasq set to dhcp_backend 'kea' while Kea's DHCPv4 config is
# still the sample of the Kea package: luci-app-kea's setup is given the
# nodes of the cluster (with the DHCP interfaces and their VIPs) and writes
# the config, what it could not set up is logged, the switch goes on as
# usual, and dnsmasq's leases are handed to the running Kea from a copy
# taken before the pool was switched off
. "$CHAR/backend/kea-switch.inc"
cp "$CHAR/backend/fixtures/kea-dhcp4-sample.conf" /etc/kea/kea-dhcp4.conf
uci set ha-cluster.peer1.source_address=172.30.0.10
export KEA_SETUP_BIN="$CHAR/stubs/kea-setup"
export FAKE_KEA_SETUP="$CHAR/backend/fixtures/kea-setup-written.json"
export FAKE_KEA_SETUP_CONF="$CHAR/backend/fixtures/kea-dhcp4-lan.conf"
export FAKE_KEA_LEASES="$CHAR/backend/fixtures/kea-leases-added.json"
export FAKE_KEA_LEASES_RC=0
rm -f /tmp/fake-kea-setup.log /tmp/fake-kea-setup.in /tmp/fake-kea-leases.log
# A client of dnsmasq: its lease is handed to Kea from the copy taken
# before the pool was switched off, which is removed afterwards
echo "1800000000 02:00:00:00:00:21 192.168.50.121 laptop 01:02:00:00:00:00:21" > /tmp/dhcp.leases
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
	echo "== copy left: $([ -e /var/run/ha-cluster/dnsmasq-leases ] && echo yes || echo no)"
}
