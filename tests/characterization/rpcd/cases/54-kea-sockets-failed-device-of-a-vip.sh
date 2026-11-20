# The failed interface is the device of a VIP on another interface than the
# instance's: a device of the cluster too
. "$CHAR/rpcd/kea-node.inc"
uci set ha-cluster.guestvip=vip
uci set ha-cluster.guestvip.vrrp_instance=main
uci set ha-cluster.guestvip.interface=eth9
uci set ha-cluster.guestvip.address=192.0.2.254
uci set ha-cluster.guestvip.netmask=255.255.255.0
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-failed-elsewhere.json"
