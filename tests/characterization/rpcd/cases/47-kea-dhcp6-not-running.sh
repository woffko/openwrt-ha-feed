# Both Kea daemons are enabled; kea-dhcp4 is in step, kea-dhcp6 does not run:
# one daemon with a problem is enough to degrade the cluster
. "$CHAR/rpcd/kea-node.inc"
uci set kea.dhcp6=service
uci set kea.dhcp6.disabled=0
: > /usr/sbin/kea-dhcp6
chmod +x /usr/sbin/kea-dhcp6
FAKE_RUNNING="keepalived owsync kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-hot-standby.json"
