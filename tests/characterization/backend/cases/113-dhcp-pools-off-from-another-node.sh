# Automatic, Kea not set up here, and the pool of 'lan' switched off for
# Kea by another node (/etc/config/dhcp is synced): this node follows the
# other one to Kea, as Kea's high availability wants Kea on both servers.
# It turns kea-dhcp4 on and Kea's init script on, as with 'kea', notes
# what it turned on for the way back, and leaves the pool as it is
. "$CHAR/backend/kea-switch.inc"
uci set dhcp.lan.dhcpv4=disabled
uci set dhcp.lan.ha_cluster_dhcpv4=unset
case_after() {
	kea_switch_after
	echo "== turned on by following: $(cat /etc/ha-cluster/kea-followed 2>/dev/null || echo '(none)')"
}
