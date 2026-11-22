# As 104, but kea-dhcp4 does not run: the pool gets its DHCPv4 back,
# /etc/config/kea and the init script are as they were, dnsmasq stays the
# server with lease-sync, and the status says why
. "$CHAR/backend/kea-switch.inc"
export FAKE_KEA_FAILS=1
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=kea; }
case_after() { kea_switch_after; }
