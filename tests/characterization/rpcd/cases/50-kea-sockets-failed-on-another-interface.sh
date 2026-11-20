# Kea could not open a socket on an interface that is not the cluster's (its
# config lists one without an address, or "*"): Kea says "failed" and goes
# on listening on br-lan. Reported as Kea says it, and not held against the
# cluster
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-failed-elsewhere.json"
