# A change to the firewall config that a user has staged and not committed
# (LuCI before "Save & Apply"): the rules of ha-cluster are committed on
# their own, the user's change stays staged and is not in the config file
uci set ha-cluster.config.bind_address=172.30.0.10
case_before_start() {
	uci set firewall.pending=rule
	uci set firewall.pending.name=Pending-rule-of-the-user
	uci set firewall.pending.src=lan
	uci set firewall.pending.target=REJECT
}
case_after() {
	echo "== staged by the user"
	uci changes firewall
	echo "== in the config file: $(grep -c 'Pending-rule-of-the-user' /etc/config/firewall) of the user's staged rule, $(grep -c "HA-Cluster-" /etc/config/firewall) rules of ha-cluster"
}
