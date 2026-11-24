# Uplink sections the validation refuses: no interface, an interface the
# network config does not have, an unknown mode, no vrrp_instance in mode
# master, an unknown vrrp_instance, the same interface twice, timers out of
# range. The cluster does not start.
. "$CHAR/backend/uplinks.inc"
uci set ha-cluster.u1=uplink
uplink_section u2 wan3 master main
uplink_section u3 wan sometimes main
uplink_section u4 wanb master
uplink_section u5 wanb always nosuch
uplink_section u6 wan master main
uci set ha-cluster.u6.retry=1
uci set ha-cluster.u6.up_delay=x
uci set ha-cluster.u6.grace=90000
