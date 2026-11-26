# Where ha-cluster sends ha-reset at the end of a maintenance: plain HTTP
# only, no path but /, a port of Kea's HA, the address of a peer that runs
# ha-cluster. Not this node's own source_address (its own HA listener),
# not a peer with VRRP only, not a port below 1024 or of the cluster's sync.
uci set ha-cluster.peer1.address=172.30.0.11
uci set ha-cluster.peer1.source_address=172.30.0.10
uci set ha-cluster.peer2=peer
uci set ha-cluster.peer2.name=node3
uci set ha-cluster.peer2.address=172.30.0.12
uci set ha-cluster.peer2.vrrp_only=1
case_after() {
	config_load ha-cluster
	echo "== partner URLs"
	for url in http://172.30.0.11:8001/ http://172.30.0.11:8001 \
		http://172.30.0.10:8001/ http://172.30.0.12:8001/ \
		http://172.30.0.11:8001/x/ha-reset 'http://172.30.0.11:8001/?a=b' \
		http://172.30.0.11:22/ http://172.30.0.11:4321/ http://172.30.0.11/ \
		https://172.30.0.11:8001/; do
		if why="$(_ha_kea_partner_refused "$url")"; then
			echo "$url: refused, $why"
		else
			echo "$url: sent"
		fi
	done
}
