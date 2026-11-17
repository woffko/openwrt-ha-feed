#!/bin/sh
# SPDX-License-Identifier: MIT
#
# The IPv6 BACKUP guard handler: which keepalived instance decides for a
# vrrp_instance section. Multicast VRRP runs the IPv6 VIPs in <section>_v6,
# unicast VRRP keeps both families in <section>. Every instance is recorded;
# the one holding the IPv6 VIPs decides, also after a reload that changes
# which one that is. Runs the handler with stand-ins for uci, nft, logger
# and /lib/functions.sh, without a router.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GUARD="$REPO_ROOT/ha-cluster/files/ipv6-backup-guard.hotplug"
TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
RUN_DIR="$TEST_ROOT/run"
STATE_DIR="$RUN_DIR/ipv6-backup-guard"
UCI_STATE="$TEST_ROOT/uci-show"
NFT_LOG="$TEST_ROOT/nft.log"
SYSLOG="$TEST_ROOT/syslog"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_BIN" "$TEST_ROOT/lib" "$RUN_DIR"

# uci: "get" on the output format of "uci show"
cat > "$FAKE_BIN/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1" = "get" ] || exit 1
awk -v key="$2" 'index($0, key "=") == 1 {
	value = substr($0, length(key) + 2)
	gsub(/^\047|\047$/, "", value)
	print value; found = 1
} END { exit !found }' "$UCI_STATE"
EOF

# nft: records the call and the script on stdin; every object exists
cat > "$FAKE_BIN/nft" <<'EOF'
#!/bin/sh
echo "CALL: $*" >> "$NFT_LOG"
case " $* " in
	*" -f - "*) cat >> "$NFT_LOG" ;;
esac
exit 0
EOF

cat > "$FAKE_BIN/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$SYSLOG"
EOF

# The handler waits a second to coalesce transitions
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/sleep"
chmod +x "$FAKE_BIN/uci" "$FAKE_BIN/nft" "$FAKE_BIN/logger" "$FAKE_BIN/sleep"

# /lib/functions.sh: the config functions the handler uses, on the same data
cat > "$TEST_ROOT/lib/functions.sh" <<'EOF'
config_load() { :; }

config_foreach() {
	local fn="$1" type="$2" section

	for section in $(awk -F'[.=]' -v type="$type" \
		'NF == 3 && $3 == type { print $2 }' "$UCI_STATE"); do
		"$fn" "$section"
	done
}

config_get() {
	local _cg_value

	_cg_value="$(uci -q get "ha-cluster.$2.$3")" || _cg_value="${4:-}"
	eval "$1=\$_cg_value"
}

config_get_bool() {
	local _cgb_value

	config_get _cgb_value "$2" "$3" "${4:-0}"
	case "$_cgb_value" in
		1|on|true|yes|enabled) _cgb_value=1 ;;
		0|off|false|no|disabled) _cgb_value=0 ;;
		*) _cgb_value="${4:-0}" ;;
	esac
	eval "$1=\$_cgb_value"
}
EOF

# Usage: guard <instance name> <action>
guard() {
	: > "$NFT_LOG"
	env -i \
		HA_GUARD_PATH="$FAKE_BIN:/usr/bin:/bin" \
		HA_GUARD_ROOT="$TEST_ROOT" \
		RUN_DIR="$RUN_DIR" \
		UCI_STATE="$UCI_STATE" NFT_LOG="$NFT_LOG" SYSLOG="$SYSLOG" \
		FAKE_NETIFD_DEVICE="${FAKE_NETIFD_DEVICE:-}" \
		ACTION="$2" TYPE=INSTANCE NAME="$1" \
		/bin/sh "$GUARD"
}

# What the init script runs after a start or a reload
reconcile() {
	guard '' RECONCILE
}

# Usage: write_uci <address6 of the VIP of main, may be empty> [<device of lan>]
write_uci() {
	cat > "$UCI_STATE" <<-EOF
		ha-cluster.config=global
		ha-cluster.main=vrrp_instance
		ha-cluster.main.interface='lan'
		ha-cluster.vip1=vip
		ha-cluster.vip1.vrrp_instance='main'
		ha-cluster.vip1.address='192.168.1.254'
		${1:+ha-cluster.vip1.address6='$1'}
		ha-cluster.guest=vrrp_instance
		ha-cluster.guest.interface='guest'
		ha-cluster.vip2=vip
		ha-cluster.vip2.vrrp_instance='guest'
		ha-cluster.vip2.address6='fd00:1::1'
		ha-cluster.other=sync_group
		network.lan=interface
		network.lan.device='${2:-br-lan}'
		network.guest=interface
		network.guest.device='br-guest'
	EOF
}

# Usage: write_keepalived_conf <instance name>...
write_keepalived_conf() {
	local name

	: > "$RUN_DIR/keepalived.conf"
	for name in "$@"; do
		printf 'vrrp_instance %s {\n    state BACKUP\n}\n' "$name" >> "$RUN_DIR/keepalived.conf"
	done
}

reset_state() {
	rm -rf "$STATE_DIR" "$RUN_DIR/ipv6-backup-guard.lock"
	: > "$SYSLOG"
}

fail() {
	echo "not ok - $1" >&2
	exit 1
}

expect() {
	label="$1"
	shift
	"$@" || fail "$label"
}

refute() {
	label="$1"
	shift
	if "$@"; then
		fail "$label"
	fi
}

blocked() {
	grep -Fq "add element inet $1 backup_ifaces { \"${2:-br-lan}\" }" "$NFT_LOG"
}

# The handler made no nft call
untouched() {
	[ ! -s "$NFT_LOG" ]
}

state_is() {
	grep -q "^$2|" "$STATE_DIR/$1.state" 2>/dev/null
}

# ------------------------------------------------------------------
# Multicast VRRP: main holds the IPv4 VIPs, main_v6 the IPv6 ones
write_uci 'fd00::1'
write_keepalived_conf main main_v6

reset_state
guard main BACKUP
expect 'the IPv4 instance does not touch the sets' untouched
expect 'its state is recorded all the same' state_is main BACKUP

guard main_v6 BACKUP
expect 'BACKUP of the IPv6 instance blocks DHCPv6' blocked ha_cluster_dhcpv6
expect 'BACKUP of the IPv6 instance blocks RA' blocked ha_cluster_ra
expect 'the state file carries the instance name' state_is main_v6 BACKUP

guard main_v6 MASTER
refute 'MASTER unblocks DHCPv6' blocked ha_cluster_dhcpv6
refute 'MASTER unblocks RA' blocked ha_cluster_ra
expect 'the sets are emptied' grep -Fxq 'CALL: flush set inet ha_cluster_ra backup_ifaces' "$NFT_LOG"
expect 'the state is MASTER' state_is main_v6 MASTER

guard main BACKUP
expect 'a BACKUP of the IPv4 instance does not block a MASTER of the IPv6 one' untouched

guard main_v6 FAULT
expect 'FAULT blocks like BACKUP' blocked ha_cluster_ra

guard main_v6 MASTER
guard main_v6 STOP
expect 'STOP blocks a MASTER for DHCPv6' blocked ha_cluster_dhcpv6
expect 'STOP blocks a MASTER for RA' blocked ha_cluster_ra
expect 'the state is BACKUP' state_is main_v6 BACKUP
echo 'ok - with multicast VRRP <section>_v6 decides'

# ------------------------------------------------------------------
# Unicast VRRP: one instance, main, holds both families
write_keepalived_conf main

reset_state
guard main BACKUP
expect 'BACKUP of the single instance blocks DHCPv6' blocked ha_cluster_dhcpv6
expect 'BACKUP of the single instance blocks RA' blocked ha_cluster_ra
expect 'the state file carries the instance name' state_is main BACKUP

guard main MASTER
refute 'MASTER of the single instance unblocks RA' blocked ha_cluster_ra
expect 'the state is MASTER' state_is main MASTER
echo 'ok - with unicast VRRP <section> itself decides'

reset_state
guard main_v6 BACKUP
expect 'an instance that is not in the keepalived config does not touch the sets' untouched
echo 'ok - an event of a <section>_v6 that no longer runs changes nothing'

# ------------------------------------------------------------------
write_uci ''
reset_state
guard main BACKUP
expect 'a single instance without an IPv6 VIP does not touch the sets' untouched

write_uci 'fd00::1'
echo "ha-cluster.vip1.enabled='0'" >> "$UCI_STATE"
reset_state
guard main BACKUP
expect 'a disabled IPv6 VIP does not count' untouched

write_uci ''
reset_state
guard main BACKUP
expect 'an IPv6 VIP of another section does not count' untouched
echo 'ok - a section without an enabled IPv6 VIP of its own is left alone'

write_uci 'fd00::1'
reset_state
guard other BACKUP
expect 'a name that is not a vrrp_instance section is not followed' untouched
refute 'and not recorded' [ -e "$STATE_DIR/other.state" ]
guard missing BACKUP
expect 'an unknown name is not followed' untouched
refute 'and not recorded' [ -e "$STATE_DIR/missing.state" ]
rm -f "$RUN_DIR/keepalived.conf"
guard main BACKUP
expect 'nothing is blocked without a keepalived config' untouched
echo 'ok - other sections, unknown names and a missing keepalived config are ignored'

# ------------------------------------------------------------------
# Several sections: each device follows its own instance, and the state of
# an instance that is gone is dropped
write_keepalived_conf main main_v6 guest guest_v6
reset_state
mkdir -p "$STATE_DIR"
echo 'BACKUP|t|BACKUP|INSTANCE|guest_v6|br-guest|fe80::5/64' > "$STATE_DIR/guest_v6.state"
echo 'BACKUP|t|BACKUP|INSTANCE|gone_v6|br-gone|fe80::5/64' > "$STATE_DIR/gone_v6.state"
guard main_v6 MASTER
expect 'the other section stays blocked' blocked ha_cluster_ra br-guest
refute 'the MASTER device is not blocked' blocked ha_cluster_ra
refute 'the state of an instance that is gone is dropped' [ -e "$STATE_DIR/gone_v6.state" ]
refute 'its device is not blocked' grep -Fq 'br-gone' "$NFT_LOG"
echo 'ok - sections are independent and the state of a removed instance does not block'

: > "$RUN_DIR/keepalived.conf"
reconcile
expect 'no state is dropped while the keepalived config holds no instance' [ -f "$STATE_DIR/guest_v6.state" ]
echo 'ok - an empty keepalived config drops no state'

# ------------------------------------------------------------------
# A reload sends no notify for an instance it keeps or removes: the init
# script asks for a reconcile
reset_state
reconcile
expect 'a reconcile with nothing recorded does nothing' untouched

# Unicast BACKUP with an IPv4 VIP only; an IPv6 VIP is added and reloaded
write_uci ''
sed -i '/vip2/d' "$UCI_STATE"
write_keepalived_conf main
reset_state
guard main BACKUP
expect 'not blocked before the IPv6 VIP exists' untouched
write_uci 'fd00::1'
reconcile
expect 'the BACKUP node is blocked once the section has an IPv6 VIP' blocked ha_cluster_ra
echo 'ok - an IPv6 VIP added by a reload blocks a BACKUP node'

# Multicast BACKUP, blocked; the IPv6 VIP is removed and reloaded
write_uci 'fd00::1'
write_keepalived_conf main main_v6
reset_state
guard main BACKUP
guard main_v6 BACKUP
expect 'blocked while it has the IPv6 VIP' blocked ha_cluster_ra
write_uci ''
write_keepalived_conf main
reconcile
refute 'no longer blocked without the IPv6 VIP' blocked ha_cluster_ra
expect 'the sets are emptied' grep -Fxq 'CALL: flush set inet ha_cluster_ra backup_ifaces' "$NFT_LOG"
refute 'the state of the removed instance is dropped' [ -e "$STATE_DIR/main_v6.state" ]
echo 'ok - an IPv6 VIP removed by a reload unblocks the node'

# Multicast to unicast: the IPv6 VIPs move from main_v6 to main
write_uci 'fd00::1'
write_keepalived_conf main main_v6
reset_state
guard main MASTER
guard main_v6 BACKUP
expect 'blocked by the IPv6 instance' blocked ha_cluster_ra
write_keepalived_conf main
reconcile
refute 'the MASTER that now holds the IPv6 VIPs is not blocked' blocked ha_cluster_ra
reset_state
write_keepalived_conf main main_v6
guard main BACKUP
guard main_v6 MASTER
write_keepalived_conf main
reconcile
expect 'the BACKUP that now holds the IPv6 VIPs is blocked' blocked ha_cluster_ra
echo 'ok - a change of transport follows the instance that holds the IPv6 VIPs'

# A node upgraded from a release that recorded <section>_v6 only
write_keepalived_conf main
reset_state
mkdir -p "$STATE_DIR"
echo 'BACKUP|t|BACKUP|INSTANCE|main_v6|br-lan|fe80::5/64' > "$STATE_DIR/main_v6.state"
reconcile
refute 'a state left by an instance that is gone does not block' blocked ha_cluster_ra
echo 'ok - a state file of an earlier release does not block the single instance'

# The device and the link-local address are those of the config in force
write_uci 'fd00::1' br-new
write_keepalived_conf main main_v6
reset_state
mkdir -p "$STATE_DIR"
echo 'BACKUP|t|BACKUP|INSTANCE|main_v6|br-lan|fe80::5/64' > "$STATE_DIR/main_v6.state"
reconcile
expect 'the device of the current config is blocked' blocked ha_cluster_ra br-new
refute 'the recorded device is not' blocked ha_cluster_ra br-lan
echo 'ok - a reconcile uses the device of the current config'

# ------------------------------------------------------------------
# The device is the one netifd reports, which the generator gives to
# keepalived; the network config is the fallback
write_uci 'fd00::1'
write_keepalived_conf main main_v6
mkdir -p "$TEST_ROOT/lib/functions"
cat > "$TEST_ROOT/lib/functions/network.sh" <<'EOF'
network_get_device() {
	[ "$2" = "lan" ] && [ -n "${FAKE_NETIFD_DEVICE:-}" ] || return 1
	eval "$1=\$FAKE_NETIFD_DEVICE"
}
EOF
reset_state
FAKE_NETIFD_DEVICE=br-real guard main_v6 BACKUP
expect 'the device netifd reports is blocked' blocked ha_cluster_ra br-real
refute 'the device of the network config is not' blocked ha_cluster_ra
reset_state
guard main_v6 BACKUP
expect 'without an answer from netifd the network config decides' blocked ha_cluster_ra
rm -rf "$TEST_ROOT/lib/functions"
echo 'ok - the blocked device is the one netifd reports, else the one of the network config'

echo 'All IPv6 BACKUP guard tests passed.'
