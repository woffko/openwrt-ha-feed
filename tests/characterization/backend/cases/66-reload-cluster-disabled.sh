# Reload after HA was disabled in the config: the node leaves the cluster,
# and the recorded IPv6 BACKUP guard state goes with it
STEP2=reload
step2() {
	mkdir -p /var/run/ha-cluster/ipv6-backup-guard
	echo 'BACKUP|t|BACKUP|INSTANCE|main|lan|' > /var/run/ha-cluster/ipv6-backup-guard/main.state
	uci set ha-cluster.config.enabled=0
}
