# /etc/config/firewall changed after the start (a rule of the cluster
# changed by hand and applied, or a file that config sync brought from a
# node that took this node's rules out): procd runs "firewall_changed",
# which writes this node's rules again and notes that it did
uci set ha-cluster.config.bind_address=172.30.0.10
STEP2=firewall_changed
step2() {
	uci set firewall.ha_cluster_owsync.dest_port=1
	uci -q delete firewall.ha_cluster_ping
}
