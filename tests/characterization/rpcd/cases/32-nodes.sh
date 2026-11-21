# The nodes as a DHCP server pair needs them: this node's address towards
# its peer comes from the peer's source_address; the node whose name sorts
# first is suggested as Kea's primary
RPCD_METHOD=nodes
uci set ha-cluster.peer1.source_address=172.30.0.10
