# The node starts in maintenance kept across reboots: keepalived's config
# follows the files from the first start, 0 1 (the lowest priority)
uci set ha-cluster.config.maintenance=1
case_after() {
	echo "== fault $(cat "$HA_MAINTENANCE_FAULT") demote $(cat "$HA_MAINTENANCE_DEMOTE")"
}
