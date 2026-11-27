# The monitor's look at Kea during a maintenance (ha_maintenance_kea_check):
# it calls the resume when the node is in maintenance, holds no role, and a
# Kea daemon with HA says hot-standby or load-balancing; not otherwise.
# That state arises when Kea was not running as the maintenance was entered
# and came up after the resume's two minutes. Kea, keepalived's states and
# the resume itself are stand-ins here: the decision is what is tested.
case_after() {
	ha_maintenance_kea_resume_bg() { echo "   resume called"; }
	ha_dhcp_backend_is_kea() { [ "$BACKEND" = kea ]; }
	_ha_keepalived_states() { echo "main $VRRP"; }
	_ha_kea_ha_state() {
		_hk_answered=1; _hk_ha=1; _hk_partner_state=""; _hk_in_touch=1
		[ "$1" = dhcp4 ] && _hk_state="$KEA4" || { _hk_state="$KEA6"; [ -n "$KEA6" ] || _hk_ha=0; }
	}
	look() { # title, maintenance (none|temp), backend, VRRP state, Kea dhcp4, Kea dhcp6
		rm -f "$HA_MAINTENANCE_TEMP"
		[ "$2" = temp ] && echo "temp 1" > "$HA_MAINTENANCE_TEMP"
		BACKEND="$3" VRRP="$4" KEA4="$5" KEA6="$6"
		: > "$CHAR_LOG"
		echo "== $1"
		ha_maintenance_kea_check
		grep -o 'Maintenance: Kea.*' "$CHAR_LOG" | sed 's/^/   /'
	}
	ha_ensure_run_dir
	look "no maintenance, Kea hot-standby" none kea BACKUP hot-standby ""
	look "maintenance, Kea in-maintenance" temp kea FAULT in-maintenance ""
	look "maintenance, Kea hot-standby (came up late)" temp kea FAULT hot-standby ""
	look "maintenance, only dhcp6 is out of it" temp kea FAULT in-maintenance load-balancing
	look "maintenance, the node took over (MASTER), Kea partner-down" temp kea MASTER partner-down ""
	look "maintenance, the node took over (MASTER), Kea hot-standby" temp kea MASTER hot-standby ""
	look "maintenance, Kea still waiting for its partner" temp kea FAULT waiting ""
	look "maintenance with dnsmasq" temp dnsmasq FAULT hot-standby ""
	rm -f "$HA_MAINTENANCE_TEMP"
	: > "$CHAR_LOG"
}
