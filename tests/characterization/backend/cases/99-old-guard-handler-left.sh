# The handler of this release in place, and one of the two handlers of an
# earlier release that it replaced still in /etc/hotplug.d/keepalived:
# keepalived would run both. The start removes the old one.
case_before_start() {
	printf '#!/bin/sh\n' > /etc/hotplug.d/keepalived/21-RA-backup-guard
}

case_after() {
	echo "== guard handlers"
	ls /etc/hotplug.d/keepalived | grep 'backup-guard'
}
