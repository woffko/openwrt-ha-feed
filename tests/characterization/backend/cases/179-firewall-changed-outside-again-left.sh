# The same a second time within ten minutes of the first: two nodes whose
# settings differ would write the one firewall config in turns for ever,
# each write setting off the other node's. The rules are left as they are,
# and a warning says why and what writes them
uci set ha-cluster.config.bind_address=172.30.0.10
STEP2=firewall_changed
step2() {
	uci set firewall.ha_cluster_owsync.dest_port=1
	echo "$(( $(date +%s) - 60 ))" > /var/run/ha-cluster/firewall-written-on-change
}
