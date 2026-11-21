# "/etc/init.d/ha-cluster reload" through rc.common after the config was
# made invalid (an unknown DHCP backend): the start it makes fails, and so
# does the reload. It used to return 0 with no daemon running, and LuCI's
# apply reported success
STEP2=init-reload
step2() {
	uci set ha-cluster.config.dhcp_backend=isc
}
