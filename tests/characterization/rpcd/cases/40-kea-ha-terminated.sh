# Kea has ended its high availability (as it does when the clocks of the
# two servers are more than a minute apart): degraded
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-terminated.json"
