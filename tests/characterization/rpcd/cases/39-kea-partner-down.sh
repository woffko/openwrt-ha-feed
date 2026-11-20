# Kea serves alone, its partner is gone: degraded, though VRRP sees the peer
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-partner-down.json"
