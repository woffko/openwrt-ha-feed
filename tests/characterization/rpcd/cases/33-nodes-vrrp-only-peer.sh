# A second peer that only speaks VRRP gets a name but no part in the DHCP
# pair, though its name sorts first; bind_address gives this node's address
# when a peer has no source_address, and this node is the standby. A peer
# section without an address is left out
RPCD_METHOD=nodes
uci set ha-cluster.config.bind_address=172.30.0.12
uci set ha-cluster.config.node_priority=150
uci set ha-cluster.config.dhcp_backend=kea
uci set ha-cluster.box=peer
uci set ha-cluster.box.name=switch
uci set ha-cluster.box.address=172.30.0.1
uci set ha-cluster.box.vrrp_only=1
uci set ha-cluster.ghost=peer
uci set ha-cluster.ghost.name=ghost
