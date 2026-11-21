# The nodes reach each other over IPv6: the rules carry the IPv6 addresses,
# this node's own taken from the peer's source_address
uci set ha-cluster.peer1.address=fd00:172:30::11
uci set ha-cluster.peer1.source_address=fd00:172:30::10
