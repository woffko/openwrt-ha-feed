# Kea follows the role of the node outside a maintenance
# (ha_kea_follow_role). Kea's servers watch each other over the sync link
# and know nothing of VRRP:
#   fault  an instance on an interface with DHCP pools is in FAULT: Kea of
#          this node in-maintenance when the peer can take over, back when
#          the FAULT is over
#   link   the node is BACKUP there (the MASTER is heard on the LAN) and no
#          peer answers on the sync link at two looks in a row, while Kea
#          has lost its partner: Kea in-maintenance alone, back when the
#          partner is heard again, serving at once when the node becomes
#          MASTER
# Kea, the check of the peer and the answers to ping are stand-ins: the
# decisions are what is tested. The peer of the fixture is 172.30.0.11.
case_after() {
	ha_dhcp_backend_is_kea() { [ -z "$DNSMASQ" ]; }
	# Kea's HA state as a file: "<state> <partner state> <interrupted>"
	echo "hot-standby hot-standby false" > /tmp/kea.state
	_ha_kea_ha_state() {
		_hk_answered=1; _hk_ha=0; _hk_in_touch=1
		[ "$1" = dhcp4 ] || return 0
		_hk_ha=1
		read -r _hk_state _hk_partner_state _hk_interrupted < /tmp/kea.state
	}
	ha_kea_maintenance() {
		echo "   kea: $1${HA_KEA_ENTER_ALONE:+ (alone)}"
		case "$1" in
			enter) echo "in-maintenance ${KEA_PARTNER:-partner-in-maintenance} ${KEA_CUT:-false}" > /tmp/kea.state ;;
			leave) echo "hot-standby hot-standby false" > /tmp/kea.state ;;
			takeover) echo "partner-down unavailable true" > /tmp/kea.state ;;
		esac
	}
	ha_maintenance_peer_problem() { [ -n "$PROBLEM" ] && echo "$PROBLEM"; }
	look() { # title, how, role of the instance, peer answers (yes|no)
		ha_role_record main "$3"
		[ "$4" = yes ] && FAKE_ONLINE="172.30.0.11" || FAKE_ONLINE=""
		export FAKE_ONLINE
		: > "$CHAR_LOG"
		echo "== $1"
		ha_kea_follow_role "$2"
		grep -oE 'ha-cluster\|daemon\.[a-z]+\|.*' "$CHAR_LOG" | sed 's/^ha-cluster|daemon\.[a-z]*|/   log: /'
		echo "   mark: $(cut -d' ' -f1 "$HA_KEA_ASIDE" 2>/dev/null || echo none), kea: $(cut -d' ' -f1 /tmp/kea.state)"
	}
	ha_ensure_run_dir
	echo "== instances with DHCP: $(_ha_kea_dhcp_roles refresh; echo "$_hkr_instances")"
	look "MASTER, all well" monitor MASTER yes
	look "FAULT, the peer can take over" event FAULT yes
	look "FAULT still" monitor FAULT yes
	echo "hot-standby hot-standby false" > /tmp/kea.state
	look "FAULT still, Kea was restarted and serves (the minute's look)" verify FAULT yes
	look "BACKUP again" event BACKUP yes
	PROBLEM="Kea's partner is partner-in-maintenance: the peer is in maintenance"
	look "FAULT, the peer cannot take over" event FAULT yes
	look "FAULT, the same refusal is not said twice" monitor FAULT yes
	PROBLEM=""
	look "BACKUP" event BACKUP yes
	echo "hot-standby hot-standby false" > /tmp/kea.state
	look "BACKUP, the peer does not answer, first look" monitor BACKUP no
	look "BACKUP, second look, Kea still hears its partner (ping is blocked, the link works)" monitor BACKUP no
	echo "partner-down unavailable true" > /tmp/kea.state
	KEA_PARTNER=unavailable KEA_CUT=true
	look "BACKUP, the peer does not answer and Kea has lost its partner" monitor BACKUP no
	look "BACKUP, a VRRP report in between" event BACKUP no
	look "MASTER: the peer is gone from the LAN too" event MASTER no
	look "BACKUP again, the peer silent (first look)" monitor BACKUP no
	look "BACKUP, second look" monitor BACKUP no
	echo "in-maintenance unavailable true" > /tmp/kea.state
	look "the peer answers, Kea does not hear its partner yet" monitor BACKUP yes
	echo "in-maintenance partner-down false" > /tmp/kea.state
	KEA_PARTNER="" KEA_CUT=""
	look "the peer answers and Kea hears its partner" monitor BACKUP yes
	look "FAULT, then a maintenance of the node" event FAULT yes
	echo "temp 1" > "$HA_MAINTENANCE_TEMP"
	look "in maintenance: the mark goes, Kea is the maintenance's" monitor FAULT yes
	rm -f "$HA_MAINTENANCE_TEMP"
	echo "hot-standby hot-standby false" > /tmp/kea.state
	DNSMASQ=1
	look "FAULT with dnsmasq as the DHCP server" event FAULT yes
	: > "$CHAR_LOG"
}
