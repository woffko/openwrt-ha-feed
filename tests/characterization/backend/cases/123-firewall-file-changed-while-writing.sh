# owsync brings a firewall config (it replaces the file without uci's lock)
# while ha-cluster writes its rules: the change is seen, the rules are
# written again on the new file, and the rule owsync brought is kept
uci set ha-cluster.config.bind_address=172.30.0.10
export HA_FIREWALL_HOLD=2
case_before_start() {
	( sleep 1; printf "\nconfig rule 'brought_by_owsync'\n\toption name 'Brought-by-owsync'\n\toption src 'lan'\n\toption target 'ACCEPT'\n" >> /etc/config/firewall ) &
}
case_after() {
	echo "== in the config file: $(grep -c 'Brought-by-owsync' /etc/config/firewall) of the rule owsync brought, $(grep -c "HA-Cluster-" /etc/config/firewall) rules of ha-cluster"
}
