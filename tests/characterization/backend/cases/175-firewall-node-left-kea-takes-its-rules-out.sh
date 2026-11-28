# This node wrote the rules of the cluster while it ran Kea (what it noted
# then) and runs dnsmasq now: the rules of Kea's high availability were its
# own and it needs them no more, so the rules are written anew as a whole
# and those two are gone
uci set ha-cluster.config.bind_address=172.30.0.10
uci set firewall.ha_cluster_kea=rule
uci set firewall.ha_cluster_kea.name=HA-Cluster-Kea-HA
uci set firewall.ha_cluster_kea.src='*'
uci add_list firewall.ha_cluster_kea.proto=tcp
uci add_list firewall.ha_cluster_kea.src_ip=172.30.0.10
uci add_list firewall.ha_cluster_kea.src_ip=172.30.0.11
uci add_list firewall.ha_cluster_kea.dest_port=8001
uci set firewall.ha_cluster_kea.target=ACCEPT
uci set firewall.ha_cluster_kea_drop=rule
uci set firewall.ha_cluster_kea_drop.name=HA-Cluster-Kea-HA-drop
uci set firewall.ha_cluster_kea_drop.src='*'
uci add_list firewall.ha_cluster_kea_drop.proto=tcp
uci add_list firewall.ha_cluster_kea_drop.dest_port=8001
uci set firewall.ha_cluster_kea_drop.target=DROP
mkdir -p /etc/ha-cluster
echo kea > /etc/ha-cluster/firewall-dhcp-server
case_after() { echo "== the DHCP server the rules were written for"; cat /etc/ha-cluster/firewall-dhcp-server 2>/dev/null || echo "(not noted)"; }
