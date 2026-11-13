#!/bin/sh
# SPDX-License-Identifier: MIT
#
# The IPv6 BACKUP guard handler: which keepalived instance it follows for a
# vrrp_instance section. Multicast VRRP runs the IPv6 VIPs in <section>_v6,
# unicast VRRP keeps both families in <section>. Runs the handler with
# stand-ins for uci, nft, logger and /lib/functions.sh, without a router.

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
		ACTION="$2" TYPE=INSTANCE NAME="$1" \
		/bin/sh "$GUARD"
}

# Usage: write_uci <address6 of the VIP of main, may be empty>
write_uci() {
	cat > "$UCI_STATE" <<-EOF
		ha-cluster.config=global
		ha-cluster.main=vrrp_instance
		ha-cluster.main.interface='lan'
		ha-cluster.vip1=vip
		ha-cluster.vip1.vrrp_instance='main'
		ha-cluster.vip1.address='192.168.1.254'
		${1:+ha-cluster.vip1.address6='$1'}
		ha-cluster.other=sync_group
		network.lan=interface
		network.lan.device='br-lan'
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
	grep -Fq "add element inet $1 backup_ifaces { \"br-lan\" }" "$NFT_LOG"
}

ignored() {
	[ ! -s "$NFT_LOG" ] && [ ! -e "$STATE_DIR" ]
}

# ------------------------------------------------------------------
# Multicast VRRP: main holds the IPv4 VIPs, main_v6 the IPv6 ones
write_uci 'fd00::1'
write_keepalived_conf main main_v6

reset_state
guard main BACKUP
expect 'the IPv4 instance is not followed' ignored

guard main_v6 BACKUP
expect 'BACKUP of the IPv6 instance blocks DHCPv6' blocked ha_cluster_dhcpv6
expect 'BACKUP of the IPv6 instance blocks RA' blocked ha_cluster_ra
expect 'the state file carries the section name' [ -f "$STATE_DIR/main.state" ]
refute 'no state file carries the instance name' [ -e "$STATE_DIR/main_v6.state" ]
expect 'the state is BACKUP on the device' grep -q '^BACKUP|.*|br-lan|' "$STATE_DIR/main.state"

guard main_v6 MASTER
refute 'MASTER unblocks DHCPv6' blocked ha_cluster_dhcpv6
refute 'MASTER unblocks RA' blocked ha_cluster_ra
expect 'the sets are emptied' grep -Fxq 'CALL: flush set inet ha_cluster_ra backup_ifaces' "$NFT_LOG"
expect 'the state is MASTER' grep -q '^MASTER|' "$STATE_DIR/main.state"

guard main_v6 FAULT
expect 'FAULT blocks like BACKUP' blocked ha_cluster_ra
echo 'ok - with multicast VRRP the handler follows <section>_v6 only'

# ------------------------------------------------------------------
# Unicast VRRP: one instance, main, holds both families
write_keepalived_conf main

reset_state
guard main BACKUP
expect 'BACKUP of the single instance blocks DHCPv6' blocked ha_cluster_dhcpv6
expect 'BACKUP of the single instance blocks RA' blocked ha_cluster_ra
expect 'the state file carries the section name' [ -f "$STATE_DIR/main.state" ]

guard main MASTER
refute 'MASTER of the single instance unblocks RA' blocked ha_cluster_ra
expect 'the state is MASTER' grep -q '^MASTER|' "$STATE_DIR/main.state"
echo 'ok - with unicast VRRP the handler follows <section> itself'

reset_state
guard main_v6 BACKUP
expect 'an instance that is not in the keepalived config is not followed' ignored
echo 'ok - an event of a <section>_v6 that no longer runs is ignored'

# ------------------------------------------------------------------
write_uci ''
reset_state
guard main BACKUP
expect 'a single instance without an IPv6 VIP is not followed' ignored

write_uci 'fd00::1'
echo "ha-cluster.vip1.enabled='0'" >> "$UCI_STATE"
reset_state
guard main BACKUP
expect 'a disabled IPv6 VIP does not count' ignored

write_uci ''
cat >> "$UCI_STATE" <<-'EOF'
	ha-cluster.vip2=vip
	ha-cluster.vip2.vrrp_instance='guest'
	ha-cluster.vip2.address6='fd00:1::1'
EOF
reset_state
guard main BACKUP
expect 'an IPv6 VIP of another section does not count' ignored
echo 'ok - a section without an enabled IPv6 VIP of its own is left alone'

write_uci 'fd00::1'
reset_state
guard other BACKUP
expect 'a name that is not a vrrp_instance section is not followed' ignored
guard missing BACKUP
expect 'an unknown name is not followed' ignored
rm -f "$RUN_DIR/keepalived.conf"
guard main BACKUP
expect 'nothing is followed without a keepalived config' ignored
echo 'ok - other sections, unknown names and a missing keepalived config are ignored'

# ------------------------------------------------------------------
# State files written by a release that named them after the instance
write_keepalived_conf main main_v6
reset_state
mkdir -p "$STATE_DIR"
echo 'BACKUP|t|BACKUP|INSTANCE|main_v6|br-lan|fe80::5/64' > "$STATE_DIR/main_v6.state"
echo 'BACKUP|t|BACKUP|INSTANCE|gone_v6|br-gone|fe80::5/64' > "$STATE_DIR/gone_v6.state"
guard main_v6 MASTER
refute 'the file named after the instance is gone' [ -e "$STATE_DIR/main_v6.state" ]
expect 'the section holds the new state' grep -q '^MASTER|' "$STATE_DIR/main.state"
refute 'the state of an instance that is gone is dropped' [ -e "$STATE_DIR/gone_v6.state" ]
refute 'its device is not blocked' grep -Fq 'br-gone' "$NFT_LOG"
refute 'the MASTER device is not blocked' blocked ha_cluster_ra
echo 'ok - state files of earlier releases and of removed instances do not block a MASTER'

# A file named after the instance takes the section name when the section
# has no state yet, so that the block it stands for is kept
write_uci 'fd00::1'
cat >> "$UCI_STATE" <<-'EOF'
	ha-cluster.guest=vrrp_instance
	ha-cluster.guest.interface='guest'
	ha-cluster.vip2=vip
	ha-cluster.vip2.vrrp_instance='guest'
	ha-cluster.vip2.address6='fd00:1::1'
	network.guest=interface
	network.guest.device='br-guest'
EOF
write_keepalived_conf main main_v6 guest guest_v6
reset_state
mkdir -p "$STATE_DIR"
echo 'BACKUP|t|BACKUP|INSTANCE|guest_v6|br-guest|fe80::5/64' > "$STATE_DIR/guest_v6.state"
guard main_v6 MASTER
expect 'the other section keeps its state under its own name' grep -q '^BACKUP|.*|br-guest|' "$STATE_DIR/guest.state"
expect 'its device stays blocked' grep -Fq 'add element inet ha_cluster_ra backup_ifaces { "br-guest" }' "$NFT_LOG"
echo 'ok - a state file of an earlier release keeps blocking its BACKUP device'

echo 'All IPv6 BACKUP guard tests passed.'
