# This node runs Kea. /etc/config/firewall holds the rule of lease-sync,
# which a node that still runs dnsmasq wrote (a pair that is moved to Kea
# node by node): it is that node's and is left as it is, next to the rules
# of Kea's high availability this node writes from its own Kea config
uci set ha-cluster.config.dhcp_backend=kea
uci set ha-cluster.config.bind_address=172.30.0.10
uci delete dhcp.lan.force
: > /etc/config/kea
uci set kea.dhcp4=service
uci set kea.dhcp4.disabled=0
mkdir -p /etc/kea
printf '%s\n' '"interfaces-config": { "service-sockets-max-retries": 60 },' '"library": "/usr/lib/kea/hooks/libdhcp_ha.so",' \
	'"url": "http://172.30.0.10:8001/",' '"url": "http://172.30.0.11:8001/"' > /etc/kea/kea-dhcp4.conf
uci set firewall.ha_cluster_lease_sync=rule
uci set firewall.ha_cluster_lease_sync.name=HA-Cluster-lease-sync
uci set firewall.ha_cluster_lease_sync.src='*'
uci add_list firewall.ha_cluster_lease_sync.proto=udp
uci add_list firewall.ha_cluster_lease_sync.src_ip=172.30.0.10
uci add_list firewall.ha_cluster_lease_sync.src_ip=172.30.0.11
uci add_list firewall.ha_cluster_lease_sync.dest_port=5378
uci set firewall.ha_cluster_lease_sync.target=ACCEPT
STEP2=reload
case_after() { echo "== the DHCP server the rules were written for"; cat /etc/ha-cluster/firewall-dhcp-server 2>/dev/null || echo "(not noted)"; }
