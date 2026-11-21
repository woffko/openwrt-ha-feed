# Two sockets failed, one of them on the device of the cluster: degraded, and
# the reason passed on is the one about that device, not the first one
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-failed-both.json"
