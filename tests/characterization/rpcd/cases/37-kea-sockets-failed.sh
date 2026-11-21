# The same with a Kea that has given up on its sockets (no retries set)
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-failed.json"
