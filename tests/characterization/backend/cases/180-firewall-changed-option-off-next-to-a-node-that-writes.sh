# option firewall '0' on this node, and the rules are in the file again
# (another node, with the option on, wrote them and config sync brought the
# file): taken out once on the change of the file, and left the second time
# within ten minutes, with the warning
uci set ha-cluster.config.bind_address=172.30.0.10
uci set ha-cluster.config.firewall=0
STEP2=firewall_changed
step2() {
	uci set firewall.ha_cluster_ping=rule
	uci set firewall.ha_cluster_ping.name=HA-Cluster-ping
	uci set firewall.ha_cluster_ping.src='*'
	uci set firewall.ha_cluster_ping.proto=icmp
	uci set firewall.ha_cluster_ping.target=ACCEPT
	echo "$(( $(date +%s) - 60 ))" > /var/run/ha-cluster/firewall-written-on-change
}
