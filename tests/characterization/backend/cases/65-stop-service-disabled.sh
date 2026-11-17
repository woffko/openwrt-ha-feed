# Stop of a node whose service no longer starts at boot: it leaves the
# cluster, and the recorded IPv6 BACKUP guard state goes with it
STEP2=stop
step2() {
	mkdir -p /var/run/ha-cluster/ipv6-backup-guard
	echo 'BACKUP|t|BACKUP|INSTANCE|main|lan|' > /var/run/ha-cluster/ipv6-backup-guard/main.state
	rm -f /etc/rc.d/S[0-9][0-9]ha-cluster
}
