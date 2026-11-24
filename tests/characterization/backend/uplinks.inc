# Uplink cases: a network config with a PPPoE wan and a static wanb (the
# rootfs has none), netifd's answers from /tmp/ifstatus, and a clock of the
# role states that stands still (uptime 1000 s)
mkdir -p /tmp/ifstatus /tmp/fake-proc
echo "1000.00 2000.00" > /tmp/fake-proc/uptime
export HA_PROC_DIR=/tmp/fake-proc
export FAKE_IFSTATUS_DIR=/tmp/ifstatus
cat > /etc/config/network <<'NET'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.50.1'
	option netmask '255.255.255.0'

config interface 'wan'
	option device 'eth2'
	option proto 'pppoe'

config interface 'wanb'
	option device 'eth0'
	option proto 'static'
	option ipaddr '10.0.100.101'
	option netmask '255.255.255.0'
NET

# Usage: ifstatus_fixture <interface> <up> <pending> <autostart> [<error code>]
ifstatus_fixture() {
	local errors=""

	[ -n "$5" ] && errors=", \"errors\": [ { \"subsystem\": \"pppoe\", \"code\": \"$5\" } ]"
	printf '{ "up": %s, "pending": %s, "autostart": %s%s }\n' "$2" "$3" "$4" "$errors" \
		> "/tmp/ifstatus/$1.json"
}

# Usage: uplink_section <name> <interface> <mode> [<vrrp_instance>]
uplink_section() {
	uci set "ha-cluster.$1=uplink"
	uci set "ha-cluster.$1.interface=$2"
	uci set "ha-cluster.$1.mode=$3"
	[ -n "$4" ] && uci set "ha-cluster.$1.vrrp_instance=$4"
	return 0
}

# Usage: uplinks_round
# One round of the uplinks, as the role program and its monitor run it
uplinks_round() {
	config_load ha-cluster
	ha_role_locked ha_uplinks_reconcile
	echo "== uplink states"
	for f in "$HA_ROLE_DIR"/uplink.*; do
		[ -f "$f" ] && echo "${f##*/}: $(cat "$f")"
	done
	echo "== log of the round"
	cat "$CHAR_LOG"
	: > "$CHAR_LOG"
}

show_network_auto() {
	echo "== network auto"
	uci -q show network | grep -E '\.(auto|ha_cluster_auto)=' || echo "(none)"
}
