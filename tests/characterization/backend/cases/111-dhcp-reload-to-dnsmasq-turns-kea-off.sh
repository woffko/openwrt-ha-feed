# A node that switched to Kea by itself (automatic) set to dhcp_backend
# 'dnsmasq': kea-dhcp4, which serves 'lan', is switched off in
# /etc/config/kea and Kea restarted first, then the pool gets its DHCPv4
# back and lease-sync runs
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=dnsmasq; }
case_after() { kea_switch_after; }
