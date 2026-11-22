# The import answers result false with exit code 0, as luci-app-kea's ubus
# method does: taken as a failure, the switch is not made
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
export FAKE_KEA_IMPORT="$CHAR/backend/fixtures/kea-import-failed.json"
case_after() { kea_switch_after; }
