# Automatic, Kea set up and running, two static leases of dnsmasq left by
# the import: listed in the status, which stays HEALTHY
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
export FAKE_KEA_IMPORT="$CHAR/backend/fixtures/kea-import-left.json"
