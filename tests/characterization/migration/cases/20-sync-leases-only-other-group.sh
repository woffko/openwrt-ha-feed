# sync_leases on a group other than dhcp was never read: it is dropped
# and does not become lease_sync, even when that group comes first and
# dhcp has no switch of its own
cat > /etc/config/ha-cluster <<'CONF'
config global 'config'
	option enabled '1'

config service 'firewall'
	option enabled '1'
	option sync_leases '1'
	list config_files 'firewall'

config service 'dhcp'
	option enabled '1'
	list config_files 'dhcp'
CONF
