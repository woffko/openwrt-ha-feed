# Automatic, on Kea, and Kea's init script disabled at boot while kea-dhcp4
# runs and serves 'lan': back to dnsmasq, Kea restarted to run as its
# settings say and, still serving 'lan', stopped, so that one DHCP server
# answers
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
STEP2=reload
step2() { "$KEA_INIT" disable; }
case_after() { kea_switch_after; }
