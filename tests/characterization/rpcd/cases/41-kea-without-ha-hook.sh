# Kea runs and listens without its high-availability hook: reported as it
# is (no "ha" object), and not held against the cluster: the leases may be
# in a shared database
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-no-ha.json"
