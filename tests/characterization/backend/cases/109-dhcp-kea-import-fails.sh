# The import of dnsmasq's static leases fails (Kea refused the result): the
# switch is not made, the pool and Kea stay as they are
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
export FAKE_KEA_IMPORT="$CHAR/backend/fixtures/kea-import-failed.json" FAKE_KEA_IMPORT_RC=1
case_after() { kea_switch_after; }
