# A switch to Kea cut short (state 'switching', the pool already off) on a
# node where Kea is still asked for: made again, Kea runs, the pool stays
# off with what it had before the first try
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
uci set dhcp.lan.dhcpv4=disabled
uci set dhcp.lan.ha_cluster_dhcpv4=unset
mkdir -p /etc/ha-cluster
echo switching > /etc/ha-cluster/dhcp-backend
case_after() { kea_switch_after; }
