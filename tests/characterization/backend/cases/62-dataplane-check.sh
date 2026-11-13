# Package-managed dataplane check attached to an instance with IPv4 and
# IPv6 VIPs: tracked by main and by main_v6
uci set ha-cluster.lan.address6=fd00:192:168:50::254
uci set ha-cluster.lan.prefix6=64
uci set ha-cluster.check_dp=script
uci set ha-cluster.check_dp.check_type=dataplane
uci add_list ha-cluster.check_dp.vrrp_instance=main
uci set ha-cluster.check_dp.interface=br-lan
uci add_list ha-cluster.check_dp.target=192.168.50.10
uci add_list ha-cluster.check_dp.target=192.168.50.11
uci set ha-cluster.check_dp.min_success=1
uci set ha-cluster.check_dp.probe_timeout=1
uci set ha-cluster.check_dp.interval=2
uci set ha-cluster.check_dp.timeout=3
uci set ha-cluster.check_dp.rise=5
uci set ha-cluster.check_dp.fall=3
