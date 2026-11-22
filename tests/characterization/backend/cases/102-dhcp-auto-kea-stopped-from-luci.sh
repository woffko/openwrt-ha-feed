# As 101, then Kea is stopped from luci-app-kea, which sends its event:
# Kea stopped on purpose, dnsmasq gets its DHCPv4 back in the pool of 'lan'
# and lease-sync runs again. /etc/config/kea is left as it is
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
STEP2=kea_changed
step2() { "$KEA_INIT" stop; }
case_after() { kea_switch_after; }
