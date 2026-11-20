# Kea runs and its HA looks well, but it has not opened its DHCP sockets and
# is still trying (started before the interface was up): the cluster is
# degraded and the reason Kea gives is passed on
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-retrying.json"
