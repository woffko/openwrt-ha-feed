# A node whose config of the releases before 2.0 came back after the
# upgrade had migrated it, as on two routers on 2026-11-22: a first-boot
# script rebooted before /etc/init.d/done, and preinit unpacked the kept
# settings again. Service sections with sync_leases, a peer with
# sync_enabled, the persist interval, the IPv6 guard handler of an earlier
# release and one of the handlers it replaced. The start migrates the
# config and puts the handler back: owsync and lease-sync get their configs.
SKIP_MIGRATION=1
uci set ha-cluster.peer1.sync_enabled='1'
uci set ha-cluster.advanced.lease_sync_persist_interval='60'

case_before_start() {
	printf '#!/bin/sh\n# handler of an earlier release\n' > /etc/hotplug.d/keepalived/20-ipv6-backup-guard
	printf '#!/bin/sh\n' > /etc/hotplug.d/keepalived/21-RA-backup-guard
}

case_after() {
	echo "== uci after start"
	uci export ha-cluster
	echo "== guard handlers"
	ls /etc/hotplug.d/keepalived
	cmp -s /usr/lib/ha-cluster/ipv6-backup-guard /etc/hotplug.d/keepalived/20-ipv6-backup-guard &&
		echo "20-ipv6-backup-guard is the packaged one" || echo "20-ipv6-backup-guard is another"
}
