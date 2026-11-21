# "/etc/init.d/ha-cluster firewall" for a cluster that was switched off
# in the config and not yet stopped: nothing is done, the rules wait for the
# stop that takes them out
uci set ha-cluster.config.bind_address=172.30.0.10
STEP2=firewall
step2() {
	uci set ha-cluster.config.enabled=0
}
