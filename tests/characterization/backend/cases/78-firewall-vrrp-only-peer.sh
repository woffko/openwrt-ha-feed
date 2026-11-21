# A second peer that only speaks VRRP: its address is in the ping rule and
# not in the rules for the sync daemons. A peer whose address is a name gets
# no rule and a warning
uci set ha-cluster.config.bind_address=172.30.0.10
uci set ha-cluster.box=peer
uci set ha-cluster.box.name=switch
uci set ha-cluster.box.address=172.30.0.3
uci set ha-cluster.box.vrrp_only=1
uci set ha-cluster.named=peer
uci set ha-cluster.named.name=named
uci set ha-cluster.named.address=node3.lan
uci set ha-cluster.named.vrrp_only=1
