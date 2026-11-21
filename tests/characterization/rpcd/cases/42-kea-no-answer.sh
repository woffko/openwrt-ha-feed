# Kea runs but cannot be asked (no control socket, no ucode socket module):
# nothing beyond running is known, and nothing is held against the cluster
. "$CHAR/rpcd/kea-node.inc"
FAKE_RUNNING="keepalived owsync kea-dhcp4"
