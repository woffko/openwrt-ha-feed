# "/etc/init.d/ha-cluster firewall" after the port of Kea's high
# availability changed in Kea's config: the Kea rule gets the new port, and
# no daemon is touched (nothing but the firewall lines in the second step)
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
	sed -i 's/:8001/:8010/' /etc/kea/kea-dhcp4.conf
}
