# A reload with nothing changed: the config is not written again. The
# loaded ruleset cannot be read in this harness, which stands for rules that
# are in the config and not loaded (a config owsync brought): firewall4 is
# reloaded, without a check, since nothing was written
uci set ha-cluster.config.bind_address=172.30.0.10
STEP2=reload
# A rule of the user whose name only looks like one of ha-cluster is no part
# of what is compared: it does not make the rules count as changed
uci set firewall.user_rule=rule
uci set firewall.user_rule.name=ha_cluster_lookalike
uci set firewall.user_rule.src=lan
uci set firewall.user_rule.target=ACCEPT
case_after() { echo "== the user's rule"; uci -q show firewall.user_rule; }
