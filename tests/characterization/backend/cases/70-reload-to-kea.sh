# Reload after the DHCP server was set to Kea on a node that runs dnsmasq,
# with Kea not installed: the switch is refused, dnsmasq stays the server
# with lease-sync and its overlay, and the status says why
STEP2=reload
step2() {
	uci set ha-cluster.config.dhcp_backend=kea
}
