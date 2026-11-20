# The failed interfaces have names that only contain the name of the
# cluster's device (a VLAN on it, a longer name): not the cluster's
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-failed-similar-name.json"
