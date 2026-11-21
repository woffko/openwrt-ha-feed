# Reload after the DHCP server was changed to Kea: lease-sync and the
# dnsmasq overlay go
STEP2=reload
step2() {
	uci set ha-cluster.config.dhcp_backend=kea
}
