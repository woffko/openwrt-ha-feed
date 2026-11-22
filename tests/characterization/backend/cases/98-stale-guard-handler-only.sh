# A config of this release with the IPv6 guard handler of an earlier
# release in /etc/hotplug.d/keepalived, which keepalived's state changes
# run: the start puts the packaged one back and leaves the config as it is.
case_before_start() {
	printf '#!/bin/sh\n# handler of an earlier release\n' > /etc/hotplug.d/keepalived/20-ipv6-backup-guard
	md5sum /etc/config/ha-cluster > /tmp/char-config-md5
}

case_after() {
	echo "== guard handler"
	cmp -s /usr/lib/ha-cluster/ipv6-backup-guard /etc/hotplug.d/keepalived/20-ipv6-backup-guard &&
		echo "the packaged one" || echo "another"
	echo "== config after start"
	md5sum -c /tmp/char-config-md5 >/dev/null 2>&1 && echo "same content" || echo "content changed"
}
