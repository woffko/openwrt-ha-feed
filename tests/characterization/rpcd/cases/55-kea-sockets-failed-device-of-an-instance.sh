# The instance runs on an interface that has no VIP section of its own; its
# device (eth9) is a device of the cluster, and a socket that failed there
# counts
. "$CHAR/rpcd/kea-node.inc"
uci set network.uplink=interface
uci set network.uplink.device=eth9
uci set ha-cluster.main.interface=uplink
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-failed-elsewhere.json"
