# A VRRP instance named by its device (eth0), which carries the static
# wanb and a PPPoE wan: a 'master' uplink on the PPPoE wan is allowed (its
# session has a device of its own, eth0 stays up), one on wanb is not
. "$CHAR/backend/uplinks.inc"
uci set network.wan.device=eth0
uci set ha-cluster.second=vrrp_instance
uci set ha-cluster.second.vrid=52
uci set ha-cluster.second.interface=eth0
uci set ha-cluster.second.priority=200
uci set ha-cluster.second_vip=vip
uci set ha-cluster.second_vip.vrrp_instance=second
uci set ha-cluster.second_vip.interface=eth0
uci set ha-cluster.second_vip.address=10.0.100.5
uplink_section wan wan master main
uplink_section u_wanb wanb master second
