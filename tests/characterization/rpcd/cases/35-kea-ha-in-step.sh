# Kea runs, listens and its high availability is in step with the partner:
# the daemon reports sockets and HA, and the cluster is healthy
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-hot-standby.json"
