# This node's own address towards the peer is not known (no bind_address,
# no source_address, and no route in this harness, as at boot before the
# interface is up): rules an earlier start wrote are left as they are
uci set firewall.ha_cluster_ping=rule
uci set firewall.ha_cluster_ping.name=HA-Cluster-ping
uci set firewall.ha_cluster_ping.src='*'
uci set firewall.ha_cluster_ping.proto=icmp
uci add_list firewall.ha_cluster_ping.icmp_type=echo-request
uci add_list firewall.ha_cluster_ping.src_ip=172.30.0.10
uci add_list firewall.ha_cluster_ping.src_ip=172.30.0.11
uci set firewall.ha_cluster_ping.target=ACCEPT
