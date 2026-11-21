# The service starts before netifd has brought the interface up (netifd
# answers nothing in this harness): the device of the logical interface
# comes from the network config, for the instance and for its VIP
: > /etc/config/network
uci set network.lan=interface
uci set network.lan.device=br-lan
