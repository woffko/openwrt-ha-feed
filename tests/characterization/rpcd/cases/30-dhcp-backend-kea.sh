# Kea as the DHCP server: the backend is reported, lease-sync is not wanted,
# and the two Kea daemons are listed (not installed here)
uci set ha-cluster.config.dhcp_backend=kea
# dnsmasq's DHCPv4 off in the pool of 'lan', as for Kea
uci set dhcp.lan.dhcpv4=disabled
