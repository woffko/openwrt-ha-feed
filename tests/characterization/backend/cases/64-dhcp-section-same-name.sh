# A VIP section named like a section of /etc/config/dhcp and without an
# interface of its own: it must not inherit the dhcp section's interface
# from the check for an authoritative dnsmasq, which loads that config
uci delete ha-cluster.lan.interface
