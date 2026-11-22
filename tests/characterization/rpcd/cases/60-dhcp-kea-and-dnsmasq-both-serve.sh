# A node that runs Kea while dnsmasq still gives out DHCPv4 in the pool of
# 'lan': two DHCP servers on the cluster interface, DEGRADED
. "$CHAR/rpcd/kea-node.inc"
uci delete dhcp.lan.dhcpv4
export FAKE_RUNNING="keepalived owsync lease-sync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-hot-standby.json"
