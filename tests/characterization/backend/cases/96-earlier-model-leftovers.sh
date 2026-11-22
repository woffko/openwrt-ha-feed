# A config of this release with two leftovers of the earlier model: an
# anonymous advanced section, whose options the backend misses since it
# reads that section by name, and sync_leases in a sync group, which
# nothing reads. The start names the section and drops the option, and
# keeps the global lease_sync as it is.
SKIP_MIGRATION=1
sh /char-migrate
uci -q delete ha-cluster.advanced
uci add ha-cluster advanced >/dev/null
uci set ha-cluster.@advanced[-1].log_level='2'
uci set ha-cluster.@advanced[-1].sync_interval='45'
uci set ha-cluster.dhcp.sync_leases='0'

case_after() {
	echo "== after start"
	uci show ha-cluster | grep '^ha-cluster\.\(advanced\|@advanced\)\|sync_leases\|lease_sync='
}
