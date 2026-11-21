# Entries of a sync group written as paths, as the routers' AP_controller
# group has them: owsync matches none of them. A path under /etc/config is
# named with what to write instead, the others are said to be outside what
# owsync syncs; a disabled group is not looked at, nor a relative entry with
# a slash (a file in a directory below /etc/config). Nothing stops the start
uci set ha-cluster.AP_controller=sync_group
uci set ha-cluster.AP_controller.enabled=1
uci add_list ha-cluster.AP_controller.config_files=/.ssh/known_hosts
uci add_list ha-cluster.AP_controller.config_files=/etc/config/apcontroller
uci add_list ha-cluster.AP_controller.config_files=/root/.ssh
uci add_list ha-cluster.AP_controller.config_files=apcontroller2
uci add_list ha-cluster.AP_controller.config_files=/etc/config/
uci set ha-cluster.off=sync_group
uci set ha-cluster.off.enabled=0
uci add_list ha-cluster.off.config_files=/etc/openvpn/keys
uci add_list ha-cluster.AP_controller.config_files=openvpn/keys
