# keepalived-sync installed (its library there): its hooks stay, and a start
# with the handlers of this release in place runs no migration.
export HA_SYNC_HOOK_LIB=/usr/lib/ha-cluster/role
case_before_start() {
	printf '#!/bin/sh\n\n. /lib/functions/network.sh\n. /lib/functions/keepalived/hotplug.sh\n' \
		> /etc/hotplug.d/keepalived/501-rpcd
}

case_after() {
	echo "== hooks"
	ls /etc/hotplug.d/keepalived
}
