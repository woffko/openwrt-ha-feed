# The nodes with the DHCP interfaces of the cluster: a VIP that names the
# logical interface and one that names a device (as on the routers) both
# give the logical interface, its device and the IPv4 addresses of its VIPs
# without mask; a VIP without an IPv4 address adds none
RPCD_METHOD=nodes
uci set ha-cluster.peer1.source_address=172.30.0.10
: > /etc/config/network
uci set network.lan=interface
uci set network.lan.device=br-lan
uci set network.lan.proto=static
uci set network.wifi=interface
uci set network.wifi.device=eth2.87
uci set network.wifi.proto=static
uci set ha-cluster.wifi_vip=vip
uci set ha-cluster.wifi_vip.enabled=1
uci set ha-cluster.wifi_vip.vrrp_instance=main
uci set ha-cluster.wifi_vip.interface=eth2.87
uci set ha-cluster.wifi_vip.address=10.0.87.5/24
uci set ha-cluster.wifi_ll=vip
uci set ha-cluster.wifi_ll.enabled=1
uci set ha-cluster.wifi_ll.vrrp_instance=main
uci set ha-cluster.wifi_ll.interface=wifi
uci set ha-cluster.wifi_ll.address6=fe80::9
uci set ha-cluster.lan_vip2=vip
uci set ha-cluster.lan_vip2.enabled=1
uci set ha-cluster.lan_vip2.vrrp_instance=main
uci set ha-cluster.lan_vip2.interface=br-lan
uci set ha-cluster.lan_vip2.address=192.168.50.253
