# The same check with unicast VRRP: one instance holds both families and
# tracks the check once
uci set ha-cluster.config.vrrp_transport=unicast
uci set ha-cluster.peer1.source_address=172.30.0.10
uci set ha-cluster.lan.address6=fd00:192:168:50::254
uci set ha-cluster.lan.prefix6=64
uci set ha-cluster.check_dp=script
uci set ha-cluster.check_dp.check_type=dataplane
uci add_list ha-cluster.check_dp.vrrp_instance=main
uci set ha-cluster.check_dp.interface=br-lan
uci add_list ha-cluster.check_dp.target=192.168.50.10
uci set ha-cluster.check_dp.interval=2
uci set ha-cluster.check_dp.timeout=3
