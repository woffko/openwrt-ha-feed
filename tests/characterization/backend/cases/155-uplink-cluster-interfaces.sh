# 'master' uplinks on interfaces the cluster runs on are refused: lan (the
# VRRP instance's and the VIP's), loopback, and the sync link (it carries
# bind_address). Mode always may name lan: it only brings it up.
. "$CHAR/backend/uplinks.inc"
uci set network.sync=interface
uci set network.sync.device=eth4
uci set network.sync.proto=static
uci set network.sync.ipaddr=10.0.88.1
uci set network.sync.netmask=255.255.255.0
uci set ha-cluster.config.bind_address=10.0.88.1
uplink_section u_lan lan master main
uplink_section u_lo loopback master main
uplink_section u_sync sync master main
uplink_section u_lan_always lan always
