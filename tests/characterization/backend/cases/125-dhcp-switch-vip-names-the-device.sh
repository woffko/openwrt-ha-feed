# As on the routers, the VIP names the device of its interface (br-lan),
# while the pool of /etc/config/dhcp names the logical interface (lan): the
# switch to Kea finds the pool through the network config and switches it
# off. Seen on the bench of 2026-11-22, where it was missed
. "$CHAR/backend/kea-switch.inc"
uci set ha-cluster.lan.interface=br-lan
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
case_after() { kea_switch_after; }
