# Kea says "failed" and gives no reason: nothing tells that the cluster's
# device is spared, so it counts
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-failed-no-reason.json"
