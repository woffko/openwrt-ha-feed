# kea-dhcp4 is enabled in its own config and does not run: degraded. A
# daemon that does not run is not asked: the answer that waits here must
# not show
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-hot-standby.json"
