# Stop of a node whose service no longer starts at boot: it leaves the
# cluster and its rules leave the firewall config
uci set ha-cluster.config.bind_address=172.30.0.10
STEP2=stop
step2() {
	rm -f /etc/rc.d/S[0-9][0-9]ha-cluster
}
