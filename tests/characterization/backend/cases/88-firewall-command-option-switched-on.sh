# "/etc/init.d/ha-cluster firewall" after option firewall was switched on:
# the command alone writes the rules, with no reload of the service and
# without touching a daemon
uci set ha-cluster.config.bind_address=172.30.0.10
uci set ha-cluster.config.firewall=0
STEP2=firewall
step2() {
	uci set ha-cluster.config.firewall=1
}
