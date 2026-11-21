# option firewall '0': the rules of ha-cluster that the firewall config
# holds are taken out, a rule of the user is left alone, and firewall4 is
# reloaded
uci set ha-cluster.config.firewall=0
uci set ha-cluster.config.bind_address=172.30.0.10
uci set firewall.ha_cluster_owsync=rule
uci set firewall.ha_cluster_owsync.name=HA-Cluster-owsync
uci set firewall.ha_cluster_owsync.src='*'
uci set firewall.ha_cluster_owsync.proto=tcp
uci set firewall.ha_cluster_owsync.dest_port=4321
uci set firewall.ha_cluster_owsync.target=ACCEPT
uci set firewall.user_rule=rule
uci set firewall.user_rule.name=ha_cluster_lookalike
uci set firewall.user_rule.src=lan
uci set firewall.user_rule.target=ACCEPT
case_after() { echo "== the user's rule"; uci -q show firewall.user_rule; }
