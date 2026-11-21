# Kea as the DHCP server with kea-dhcp4 installed and running, kea-dhcp6
# neither: lease-sync, which the backend does not start with Kea, is stopped
uci set ha-cluster.config.dhcp_backend=kea
FAKE_RUNNING="keepalived owsync kea-dhcp4"
: > /usr/sbin/kea-dhcp4
chmod +x /usr/sbin/kea-dhcp4
