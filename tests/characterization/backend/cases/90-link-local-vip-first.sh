# The IPv6 VIP sections in the order a user may add them: a global address
# first, its link-local after. keepalived wants the link-local address first
# in an instance, and gets it first; the global ones keep their order
uci set ha-cluster.lan.address6=fd00:192:168:50::254
uci set ha-cluster.lan.prefix6=64
uci set ha-cluster.lan2=vip
uci set ha-cluster.lan2.vrrp_instance=main
uci set ha-cluster.lan2.interface=lan
uci set ha-cluster.lan2.address6=fd00:192:168:51::254
uci set ha-cluster.lan2.prefix6=64
uci set ha-cluster.lan_ll=vip
uci set ha-cluster.lan_ll.vrrp_instance=main
uci set ha-cluster.lan_ll.interface=lan
uci set ha-cluster.lan_ll.address6=FE80::5
uci set ha-cluster.lan_ll.prefix6=64
