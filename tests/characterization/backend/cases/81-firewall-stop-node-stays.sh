# Stop of a node that stays in the cluster: the rules stay in the firewall
# config (Kea's high availability and the peer's ping do not stop with
# ha-cluster)
uci set ha-cluster.config.bind_address=172.30.0.10
STEP2=stop
