# A BACKUP: the wan (master) is down as it should be; the wanb (always),
# down for 300 s, is a warning only, the cluster stays HEALTHY. A third
# uplink waits for its up_delay on another instance where the node is MASTER.
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uci set network.lte=interface
uci set network.lte.proto=qmi
uci set network.lte.auto=0
uci set ha-cluster.second=vrrp_instance
uci set ha-cluster.second.vrid=52
uci set ha-cluster.second.interface=lan
uci set ha-cluster.second.priority=200
uci set ha-cluster.second_vip=vip
uci set ha-cluster.second_vip.vrrp_instance=second
uci set ha-cluster.second_vip.interface=lan
uci set ha-cluster.second_vip.address=192.168.50.253
uplink_section wan wan master main
uplink_section wanb wanb always main
uplink_section lte lte master second
uci set ha-cluster.lte.up_delay=60
mkdir -p /var/run/ha-cluster/role
echo "BACKUP 500" > /var/run/ha-cluster/role/instance.main
echo "MASTER 980" > /var/run/ha-cluster/role/instance.second
echo "down 500 0 0 0" > /var/run/ha-cluster/role/uplink.wan
echo "up 0 0 0 700" > /var/run/ha-cluster/role/uplink.wanb
ifstatus_fixture wan false false false USER_REQUEST
ifstatus_fixture wanb false false false NO_CARRIER
ifstatus_fixture lte false false false
