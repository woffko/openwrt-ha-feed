# Automatic, Kea set up and already running when the switch is made (it was
# started from luci-app-kea): the import changed Kea's files, so Kea is
# reloaded, not started
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
echo kea-dhcp4 > /tmp/fake-running
case_after() { kea_switch_after; }
