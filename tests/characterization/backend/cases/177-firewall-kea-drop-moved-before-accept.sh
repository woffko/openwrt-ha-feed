# This node runs Kea and its two rules for Kea's high availability are in
# the config, but the one that drops everybody else was moved before the
# one that accepts the nodes (by hand, or in LuCI's list of rules): the
# same rules, in an order that shuts the partner out. They are written
# anew in their order
uci set ha-cluster.config.dhcp_backend=kea
uci set ha-cluster.config.bind_address=172.30.0.10
uci delete dhcp.lan.force
: > /etc/config/kea
uci set kea.dhcp4=service
uci set kea.dhcp4.disabled=0
mkdir -p /etc/kea
printf '%s\n' '"interfaces-config": { "service-sockets-max-retries": 60 },' '"library": "/usr/lib/kea/hooks/libdhcp_ha.so",' \
	'"url": "http://172.30.0.10:8001/",' '"url": "http://172.30.0.11:8001/"' > /etc/kea/kea-dhcp4.conf
STEP2=firewall
step2() {
	uci reorder firewall.ha_cluster_kea_drop=0
}
case_after() { echo "== the order of the two rules of Kea"; uci -q show firewall | sed -n 's/^firewall\.\(ha_cluster_kea[a-z_]*\)=rule$/\1/p' | tr '\n' ' '; echo; }
