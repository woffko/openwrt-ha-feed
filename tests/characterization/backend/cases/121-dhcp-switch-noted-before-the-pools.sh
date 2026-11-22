# While Kea is being started the node has noted 'switching': a reboot or a
# kill at that moment, with the pool already off, is seen at the next start
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1 FAKE_KEA_LOG_STATE=1
case_after() { kea_switch_after; }
