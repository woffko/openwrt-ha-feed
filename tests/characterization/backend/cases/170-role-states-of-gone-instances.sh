# The states recorded for instances that the generated keepalived config no
# longer has are removed (ha_role_prune, at a start, a reload and the
# monitor's check): keepalived reports nothing for an instance that is
# gone, and a later config with that name would start from the old state.
# A record being written (instance.<name>.<pid>) is left alone.
case_after() {
	inst="$(sed -n 's/^vrrp_instance \([A-Za-z0-9_]*\) {$/\1/p' "$KEEPALIVED_CONF" | head -1)"
	echo "== instance of the config: $inst"
	ha_role_record "$inst" BACKUP
	ha_role_record "${inst}_v6" MASTER
	ha_role_record gone MASTER
	: > "$HA_ROLE_DIR/instance.$inst.12345"
	echo "== before: $(ls "$HA_ROLE_DIR" | grep '^instance\.' | sed "s/^instance\.$inst/instance.<inst>/" | tr '\n' ' ')"
	ha_role_prune
	echo "== after ha_role_prune: $(ls "$HA_ROLE_DIR" | grep '^instance\.' | sed "s/^instance\.$inst/instance.<inst>/" | tr '\n' ' ')"
	ha_role_record gone MASTER
	echo "== keepalived's stand-in reports: $(_ha_keepalived_states | sed "s/^$inst/<inst>/" | tr '\n' ';')"
	ha_role_sync
	echo "== after ha_role_sync: $(ls "$HA_ROLE_DIR" | grep '^instance\.' | sed "s/^instance\.$inst/instance.<inst>/" | tr '\n' ' ')"
	rm -f "$HA_ROLE_DIR/instance.$inst.12345"
}
