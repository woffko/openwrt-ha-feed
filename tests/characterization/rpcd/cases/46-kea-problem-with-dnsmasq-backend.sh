# With dnsmasq as the DHCP server Kea is not looked at
. "$CHAR/rpcd/kea-node.inc"
uci set ha-cluster.config.dhcp_backend=dnsmasq
FAKE_RUNNING="keepalived owsync lease-sync"
