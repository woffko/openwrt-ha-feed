# An image without keepalived-sync, its hooks kept by sysupgrade from one
# that had it, a hook of the administrator under one of those names, and
# the role handler deleted (LuCI's hook editor can): the start removes the
# hooks that load the missing library, keeps the other one, and puts the
# role handler of this release back.
export HA_SYNC_HOOK_LIB=/nonexistent/keepalived/hotplug.sh
case_before_start() {
	for hook in 501-rpcd 810-files; do
		printf '#!/bin/sh\n\n. /lib/functions/network.sh\n. /lib/functions/keepalived/hotplug.sh\n' \
			> "/etc/hotplug.d/keepalived/$hook"
	done
	printf '#!/bin/sh\n# a hook of the administrator\nlogger -t custom state\n' \
		> /etc/hotplug.d/keepalived/600-uhttpd
	rm -f /etc/hotplug.d/keepalived/10-ha-cluster-role
}

case_after() {
	echo "== hooks"
	ls /etc/hotplug.d/keepalived
	cmp -s /usr/lib/ha-cluster/role.hotplug /etc/hotplug.d/keepalived/10-ha-cluster-role &&
		echo "role handler: the packaged one" || echo "role handler: missing or another"
}
