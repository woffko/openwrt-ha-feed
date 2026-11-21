# The nodes reach each other over IPv6: the names are made from the
# addresses with the colons replaced too
RPCD_METHOD=nodes
uci set ha-cluster.peer1.address=fd00:172:30::11
uci set ha-cluster.peer1.source_address=fd00:172:30::10
