# As 102 (Kea the server with dhcp_backend 'kea'), with kea-dhcp4 listening
# on br-lan with this node's own address: no warning about the sockets of
# the VIP's addresses (the other Kea cases name br-lan alone and get it)
. "$CHAR/backend/kea-switch.inc"
cp "$CHAR/backend/fixtures/kea-dhcp4-lan-own-address.conf" /etc/kea/kea-dhcp4.conf
uci set ha-cluster.config.dhcp_backend=kea
case_after() { kea_switch_after; }
