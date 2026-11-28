# This node runs dnsmasq. /etc/config/firewall, which config sync brought
# from a node that runs Kea, holds the two rules of Kea's high availability:
# they are that node's, written from the ports in its Kea config, and are
# left as they are, with this node's own rules written after them. The
# reload that follows writes nothing: the sections are in another order in
# the file than they are described in, and the rules are the same
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
STEP2=reload
case_after() { echo "== the DHCP server the rules were written for"; cat /etc/ha-cluster/firewall-dhcp-server 2>/dev/null || echo "(not noted)"; }
