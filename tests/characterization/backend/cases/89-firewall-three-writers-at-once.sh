# Three writers of the rules at the same time (a start of the service, the
# "firewall" command, another caller), each made to wait a second in the
# middle of its writing: one writes, the others wait for it and find the
# rules as they should be. Each address is in each rule once
uci set ha-cluster.config.bind_address=172.30.0.10
uci set ha-cluster.config.firewall=0
STEP2=firewall
step2() {
	uci set ha-cluster.config.firewall=1
	uci commit ha-cluster
	export HA_FIREWALL_HOLD=1
	firewall &
	firewall &
	firewall &
	wait
	unset HA_FIREWALL_HOLD
	echo "== after three writers at once"
	sort "$CHAR_LOG"
	: > "$CHAR_LOG"
	uci -q show firewall | grep '^firewall\.ha_cluster_.*src_ip'
}
