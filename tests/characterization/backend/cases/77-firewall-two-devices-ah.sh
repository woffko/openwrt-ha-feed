# Two instances on two interfaces, one of them authenticating with AH: a
# VRRP rule per device, in the order of the device names, with AH next to
# VRRP. The devices come from the network config
: > /etc/config/network
uci set network.lan=interface
uci set network.lan.device=br-lan
uci set network.guest=interface
uci set network.guest.device=br-guest
uci set ha-cluster.config.bind_address=172.30.0.10
uci set ha-cluster.guest=vrrp_instance
uci set ha-cluster.guest.vrid=52
uci set ha-cluster.guest.interface=guest
uci set ha-cluster.guest.priority=200
uci set ha-cluster.guest.auth_type=ah
uci set ha-cluster.guest.auth_pass=secret12
uci set ha-cluster.guestvip=vip
uci set ha-cluster.guestvip.vrrp_instance=guest
uci set ha-cluster.guestvip.interface=guest
uci set ha-cluster.guestvip.address=192.168.60.254
uci set ha-cluster.guestvip.netmask=255.255.255.0
