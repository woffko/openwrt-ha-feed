# sync_encryption, the fork's switch, is not part of the migration: both
# spellings stay as they are
cat > /etc/config/ha-cluster <<'CONF'
config global 'config'
	option enabled '1'
	option sync_method 'owsync'
	option sync_encryption '0'

config peer 'peer1'
	option address '172.30.0.11'
	option sync_enabled '1'

config service 'dhcp'
	option enabled '1'
	option sync_leases '1'
	list config_files 'dhcp'

config advanced
	option log_level '2'
CONF
