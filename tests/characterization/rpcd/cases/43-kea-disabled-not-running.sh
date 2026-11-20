# kea-dhcp4 is disabled in its own config and does not run: that is the
# setting, not a problem
. "$CHAR/rpcd/kea-node.inc"
uci set kea.dhcp4.disabled=1
FAKE_RUNNING="keepalived owsync"
