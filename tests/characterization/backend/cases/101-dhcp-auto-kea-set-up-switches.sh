# Automatic, and Kea set up for the cluster: kea-dhcp4 on in /etc/config/kea,
# its init script enabled, its config naming br-lan. The start imports the
# static leases of dnsmasq, switches dnsmasq's DHCPv4 off in the pool of
# 'lan' (keeping that it had none), starts Kea, and runs without lease-sync
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
case_after() { kea_switch_after; }
