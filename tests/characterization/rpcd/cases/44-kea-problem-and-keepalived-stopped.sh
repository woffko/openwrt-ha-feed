# A required service that does not run makes the cluster faulty, whatever
# Kea reports
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-failed.json"
