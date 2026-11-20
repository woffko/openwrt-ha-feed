# Kea as the DHCP server with the dnsmasq pool of the VIP interface left to
# router advertisements only: no warning about two DHCP servers
uci set ha-cluster.config.dhcp_backend=kea
uci set dhcp.lan.dhcpv4=disabled
