# A rule of ha-cluster was changed by hand and one was added under its
# names: the rules are written anew as the cluster needs them
uci set ha-cluster.config.bind_address=172.30.0.10
uci set firewall.ha_cluster_owsync=rule
uci set firewall.ha_cluster_owsync.name=HA-Cluster-owsync
uci set firewall.ha_cluster_owsync.src=wan
uci set firewall.ha_cluster_owsync.proto=tcp
uci set firewall.ha_cluster_owsync.dest_port=1
uci set firewall.ha_cluster_owsync.target=ACCEPT
uci set firewall.ha_cluster_extra=rule
uci set firewall.ha_cluster_extra.name=HA-Cluster-extra
uci set firewall.ha_cluster_extra.src=wan
uci set firewall.ha_cluster_extra.target=ACCEPT
