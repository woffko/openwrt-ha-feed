# The IPv6 guard handler in /etc/hotplug.d/keepalived is one of an earlier
# release while the config is of this one (a restored backup, and a start
# that could not put the handler back): reported with the earlier model,
# DEGRADED
SKIP_MIGRATION=1
sh /char-migrate
printf '#!/bin/sh\n# handler of an earlier release\n' > /etc/hotplug.d/keepalived/20-ipv6-backup-guard
export HA_MIGRATE_CONFIG=/nonexistent/migrate-config
