# Kea as the DHCP server: no lease-sync, no dnsmasq overlay, no dhcp force
# check. Kea is not installed here and dnsmasq still has its pool on the VIP
# interface: both are warned about, neither stops the start
uci set ha-cluster.config.dhcp_backend=kea
uci delete dhcp.lan.force
