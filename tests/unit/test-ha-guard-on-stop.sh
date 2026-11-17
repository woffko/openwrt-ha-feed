#!/bin/sh
# SPDX-License-Identifier: MIT
#
# The IPv6 BACKUP guard when ha-cluster stops. A node that stops but stays
# in the cluster keeps the guard closed for every instance, whatever state
# it had; a node taken out of the cluster (HA disabled in the config, or
# the service disabled) gets the rules removed. Runs the library function
# the init script calls and the real guard handler, with stand-ins for uci,
# nft, logger and /lib/functions.sh, without a router.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
TEST_ROOT="$(mktemp -d)"
FAKE_ROOT="$TEST_ROOT/root"
FAKE_BIN="$TEST_ROOT/bin"
RUN_DIR="$TEST_ROOT/run"
STATE_DIR="$RUN_DIR/ipv6-backup-guard"
LOCK_DIR="$RUN_DIR/ipv6-backup-guard.lock"
UCI_STATE="$TEST_ROOT/uci-show"
NFT_LOG="$TEST_ROOT/nft.log"
SYSLOG="$TEST_ROOT/syslog"
BOOT_LINK="$FAKE_ROOT/etc/rc.d/S25ha-cluster"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_BIN" "$FAKE_ROOT/lib/config" "$FAKE_ROOT/etc/rc.d" \
	"$FAKE_ROOT/usr/lib/ha-cluster" "$RUN_DIR"
cp "$REPO_ROOT/ha-cluster/files/ipv6-backup-guard.hotplug" \
	"$FAKE_ROOT/usr/lib/ha-cluster/ipv6-backup-guard"

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

# /lib/functions.sh for the library and for the handler, on the same data
cat > "$FAKE_ROOT/lib/functions.sh" <<'EOF'
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

# A function: BusyBox ash runs its own logger applet before looking at PATH
logger() {
	echo "$*" >> "$SYSLOG"
}
EOF
: > "$FAKE_ROOT/lib/config/uci.sh"

# The library, and through it the handler, see only the stand-ins
PATH="$FAKE_BIN:$PATH"
export IPKG_INSTROOT="$FAKE_ROOT"
export HA_CLUSTER_RUN_DIR="$RUN_DIR"
export HA_GUARD_PATH="$FAKE_BIN:/usr/bin:/bin"
export HA_GUARD_ROOT="$FAKE_ROOT"
export RUN_DIR UCI_STATE NFT_LOG SYSLOG

. "$REPO_ROOT/ha-cluster/files/ha-cluster.sh"

# Usage: write_uci <enabled>
write_uci() {
	cat > "$UCI_STATE" <<-EOF
		ha-cluster.config=global
		ha-cluster.config.enabled='$1'
		ha-cluster.main=vrrp_instance
		ha-cluster.main.interface='lan'
		ha-cluster.vip1=vip
		ha-cluster.vip1.vrrp_instance='main'
		ha-cluster.vip1.address='192.168.1.254'
		ha-cluster.vip1.address6='fd00::1'
		ha-cluster.guest=vrrp_instance
		ha-cluster.guest.interface='guest'
		ha-cluster.vip2=vip
		ha-cluster.vip2.vrrp_instance='guest'
		ha-cluster.vip2.address6='fd00:1::1'
		network.lan=interface
		network.lan.device='br-lan'
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

# What keepalived reports for an instance while the cluster runs
notify() {
	ACTION="$2" TYPE=INSTANCE NAME="$1" /bin/sh "$FAKE_ROOT/usr/lib/ha-cluster/ipv6-backup-guard"
}

# Usage: running <service enabled at boot: 1|0> <instance=STATE>...
# A node with these instances in these states, and nothing in the logs
running() {
	local pair

	rm -rf "$STATE_DIR" "$LOCK_DIR"
	if [ "$1" -eq 1 ]; then
		: > "$BOOT_LINK"
	else
		rm -f "$BOOT_LINK"
	fi
	shift

	for pair in "$@"; do
		notify "${pair%%=*}" "${pair#*=}"
	done
	: > "$NFT_LOG"
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

# The last content given to a set holds exactly these devices
set_holds() {
	local table="$1" elements

	shift
	elements="$(grep -F "add element inet $table backup_ifaces" "$NFT_LOG" | tail -n 1)"
	[ -n "$elements" ] || return 1
	for device in "$@"; do
		case "$elements" in
			*"\"$device\""*) ;;
			*) return 1 ;;
		esac
	done
	[ "$(printf '%s\n' "$elements" | tr -cd '"' | wc -c)" -eq $(($# * 2)) ]
}

state_is() {
	grep -q "^$2|" "$STATE_DIR/$1.state" 2>/dev/null
}

tables_removed() {
	grep -Fxq 'CALL: delete table inet ha_cluster_dhcpv6' "$NFT_LOG" &&
		grep -Fxq 'CALL: delete table inet ha_cluster_ra' "$NFT_LOG"
}

says_closed() {
	grep -Fq 'IPv6 BACKUP guard stays closed' "$SYSLOG"
}

# ------------------------------------------------------------------
# Multicast VRRP, the node was MASTER of the IPv6 instance
write_uci 1
write_keepalived_conf main main_v6
running 1 main=MASTER main_v6=MASTER
ha_stop_ipv6_guard
expect 'a stopped MASTER no longer takes DHCPv6' set_holds ha_cluster_dhcpv6 br-lan
expect 'a stopped MASTER no longer advertises' set_holds ha_cluster_ra br-lan
expect 'the IPv6 instance is recorded as BACKUP' state_is main_v6 BACKUP
expect 'the IPv4 instance is recorded as BACKUP' state_is main BACKUP
refute 'the rules are not removed' tables_removed
expect 'the log says why' says_closed
echo 'ok - a node that stops while enabled is closed, even when it was MASTER'

running 1 main=BACKUP main_v6=BACKUP
ha_stop_ipv6_guard
expect 'a stopped BACKUP stays blocked for DHCPv6' set_holds ha_cluster_dhcpv6 br-lan
expect 'a stopped BACKUP stays blocked for RA' set_holds ha_cluster_ra br-lan
refute 'the rules are not removed' tables_removed
echo 'ok - a BACKUP that stops stays closed'

# ------------------------------------------------------------------
# Unicast VRRP: the single instance holds both families
write_keepalived_conf main
running 1 main=MASTER
ha_stop_ipv6_guard
expect 'the single instance is closed' set_holds ha_cluster_ra br-lan
expect 'and recorded as BACKUP' state_is main BACKUP
echo 'ok - with unicast VRRP the single instance is closed'

# ------------------------------------------------------------------
# Two sections: every one is closed
write_keepalived_conf main main_v6 guest_v6
running 1 main=MASTER main_v6=MASTER guest_v6=MASTER
ha_stop_ipv6_guard
expect 'both interfaces are blocked for RA' set_holds ha_cluster_ra br-lan br-guest
expect 'both interfaces are blocked for DHCPv6' set_holds ha_cluster_dhcpv6 br-lan br-guest
echo 'ok - every section is closed'

# ------------------------------------------------------------------
# The node leaves the cluster
write_keepalived_conf main main_v6
running 0 main=BACKUP main_v6=BACKUP
ha_stop_ipv6_guard
expect 'a disabled service gets the rules removed' tables_removed
expect 'and the recorded states' [ ! -d "$STATE_DIR" ]
refute 'nothing is blocked again' grep -Fq 'add element' "$NFT_LOG"
refute 'the log does not claim a closed guard' says_closed
echo 'ok - a node whose service is disabled is released'

write_uci 0
running 1 main=BACKUP main_v6=BACKUP
ha_stop_ipv6_guard
expect 'HA disabled in the config gets the rules removed' tables_removed
expect 'and the recorded states' [ ! -d "$STATE_DIR" ]
refute 'nothing is blocked again' grep -Fq 'add element' "$NFT_LOG"
echo 'ok - a node with HA disabled in the config is released'

# ------------------------------------------------------------------
# Never started: no keepalived config, nothing recorded
write_uci 1
running 1
rm -f "$RUN_DIR/keepalived.conf"
ha_stop_ipv6_guard
expect 'nothing is done without a keepalived config' [ ! -s "$NFT_LOG" ]
expect 'and nothing is recorded' [ ! -d "$STATE_DIR" ]
echo 'ok - a stop before any start does nothing'

# ------------------------------------------------------------------
# Another handler is at work: it will set the rules, and the stop waits
# for it before dnsmasq is restarted
write_keepalived_conf main main_v6
running 1 main=MASTER main_v6=MASTER
mkdir "$LOCK_DIR"
echo "$$" > "$LOCK_DIR/pid"
WAITS=0
sleep() {
	WAITS=$((WAITS + 1))
	[ "$WAITS" -lt 2 ] || rm -rf "$LOCK_DIR"
}
ha_stop_ipv6_guard
unset -f sleep
expect 'the state is recorded for the handler at work' state_is main_v6 BACKUP
expect 'the stop waits until that handler is done' [ "$WAITS" -eq 2 ]

mkdir "$LOCK_DIR"
echo "$$" > "$LOCK_DIR/pid"
WAITS=0
sleep() {
	WAITS=$((WAITS + 1))
}
ha_stop_ipv6_guard
unset -f sleep
rm -rf "$LOCK_DIR"
expect 'but not for ever' [ "$WAITS" -eq 5 ]
echo 'ok - the stop waits for a handler at work, for five seconds at most'

echo 'ok - ha-cluster guard on stop'
