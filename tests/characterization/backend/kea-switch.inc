# Sourced by the backend cases about the switch of the DHCP server of the
# cluster interfaces between dnsmasq and Kea. Kea is installed (kea-dhcp4 a
# stand-in), with dhcp4 off in /etc/config/kea and its init script disabled
# (the stand-in records its calls and "runs" kea-dhcp4 when dhcp4 is on).
# kea-dhcp4's config names br-lan, the device of 'lan', with a subnet for
# its address; the import of luci-app-kea is a stand-in that imports one
# lease and leaves nothing ($FAKE_KEA_IMPORT); Kea answers status-get with
# its sockets ready, and nobody waits for it.
: > /etc/config/network
uci set network.lan=interface
uci set network.lan.device=br-lan
uci set network.lan.proto=static
uci set network.lan.ipaddr=192.168.50.10/24
: > /etc/config/kea
uci set kea.dhcp4=service
uci set kea.dhcp4.disabled=1
: > /usr/sbin/kea-dhcp4
chmod +x /usr/sbin/kea-dhcp4
mkdir -p /etc/kea
cp "$CHAR/backend/fixtures/kea-dhcp4-lan.conf" /etc/kea/kea-dhcp4.conf
rm -f /tmp/fake-kea-init.log /tmp/fake-kea-enabled /tmp/fake-running /tmp/fake-kea-import.log
export KEA_INIT="$CHAR/stubs/kea-init"
export KEA_IMPORT_BIN="$CHAR/stubs/kea-import"
export FAKE_KEA_IMPORT="$CHAR/backend/fixtures/kea-import-nothing-left.json"
export KEA_STATUS_GET=kea-status-get
export FAKE_KEA4_STATUS="$CHAR/rpcd/fixtures/kea-status-hot-standby.json"
export HA_KEA_WAIT=0

# Usage: kea_switch_after
# What the switch did: the pool of 'lan', Kea's switch and init script, the
# server the node runs, and why a switch was not made
kea_switch_after() {
	echo "== pool dhcp.lan"
	uci show dhcp.lan | grep -E '\.(dhcpv4|dhcpv6|ra|ignore|ha_cluster_dhcpv4)=' || echo "(no dhcpv4 options)"
	echo "== kea.dhcp4.disabled=$(uci -q get kea.dhcp4.disabled)"
	echo "== kea init calls"
	cat /tmp/fake-kea-init.log 2>/dev/null || echo "(none)"
	echo "== kea init enabled: $(cat /tmp/fake-kea-enabled 2>/dev/null)"
	echo "== import calls: $(cat /tmp/fake-kea-import.log 2>/dev/null | wc -l)"
	echo "== running: $(cat /tmp/fake-running 2>/dev/null | tr '\n' ' ')"
	show_file /etc/ha-cluster/dhcp-backend
	show_file /var/run/ha-cluster/dhcp-backend-problem
}
