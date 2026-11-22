# The import leaves two static leases (one to review, one it cannot take):
# the switch is made, and each is named in the log
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
export FAKE_KEA_IMPORT="$CHAR/backend/fixtures/kea-import-left.json"
case_after() { kea_switch_after; }
