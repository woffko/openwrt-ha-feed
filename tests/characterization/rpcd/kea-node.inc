# Sourced by the rpcd cases about a node whose DHCP server is Kea: the
# backend is 'kea', kea-dhcp4 is installed and enabled in Kea's own config,
# kea-dhcp6 has no section there, dnsmasq's DHCPv4 is off in the pool of
# 'lan' (as it is for Kea), and the status backend asks the stand-in
# instead of a control socket. A case then says what runs (FAKE_RUNNING) and
# what Kea answers (FAKE_KEA4_STATUS, a fixture; unset: no answer).
uci set ha-cluster.config.dhcp_backend=kea
uci set dhcp.lan.dhcpv4=disabled
: > /etc/config/kea
uci set kea.dhcp4=service
uci set kea.dhcp4.disabled=0
: > /usr/sbin/kea-dhcp4
chmod +x /usr/sbin/kea-dhcp4
export KEA_STATUS_GET=kea-status-get
KEA_FIXTURES="$CHAR/rpcd/fixtures"
# The cluster's interface 'lan' is the device br-lan, as the network config
# says (netifd answers nothing in this harness)
: > /etc/config/network
uci set network.lan=interface
uci set network.lan.device=br-lan
