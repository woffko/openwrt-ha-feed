#!/bin/sh
# SPDX-License-Identifier: MIT
#
# When ha-cluster runs owsync and lease-sync, what it writes for them and
# what it says about an authoritative dnsmasq. Runs the library against a
# stubbed UCI, without a router.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
TEST_ROOT="$(mktemp -d)"
FAKE_ROOT="$TEST_ROOT/root"
CONFIG_FILE="$TEST_ROOT/config.tsv"
LOG_FILE="$TEST_ROOT/ha.log"
RUN_DIR="$TEST_ROOT/run"
BIN_DIR="$TEST_ROOT/bin"
CONF_DIR="$TEST_ROOT/dnsmasq.d"
DNSMASQ_RESTARTS="$TEST_ROOT/dnsmasq-restarts"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_ROOT/lib/config" "$RUN_DIR" "$BIN_DIR"

cat > "$FAKE_ROOT/lib/functions.sh" <<'EOF'
config_load() {
	return 0
}

config_get() {
	local destination="$1"
	local section="$2"
	local option="$3"
	local default="${4:-}"
	local resolved

	resolved=$(awk -F '\t' -v section="$section" -v option="$option" '
		$1 == section && $2 == option { print $3; found = 1; exit }
		END { if (!found) exit 1 }
	' "$TEST_CONFIG_FILE" 2>/dev/null) || resolved="$default"
	eval "$destination='${resolved}'"
}

config_get_bool() {
	local destination="$1"
	local resolved_bool
	config_get resolved_bool "$2" "$3" "${4:-0}"
	case "$resolved_bool" in
		1|on|true|yes|enabled) resolved_bool=1 ;;
		*) resolved_bool=0 ;;
	esac
	eval "$destination='$resolved_bool'"
}

config_foreach() {
	local callback="$1"
	local wanted_type="$2"
	local sections section

	sections=$(awk -F '\t' -v wanted_type="$wanted_type" '
		$2 == "TYPE" && $3 == wanted_type { print $1 }
	' "$TEST_CONFIG_FILE")
	for section in $sections; do
		[ -n "$section" ] && "$callback" "$section"
	done
}

config_list_foreach() {
	local section="$1"
	local option="$2"
	local callback="$3"
	local values value

	values=$(awk -F '\t' -v section="$section" -v option="$option" '
		$1 == section && $2 == option { print $3 }
	' "$TEST_CONFIG_FILE")
	for value in $values; do
		[ -n "$value" ] && "$callback" "$value"
	done
}

logger() {
	printf '%s\n' "$*" >> "$TEST_LOG_FILE"
}
EOF

cat > "$FAKE_ROOT/lib/config/uci.sh" <<'EOF'
# Minimal test stub.
EOF

export IPKG_INSTROOT="$FAKE_ROOT"
export HA_CLUSTER_RUN_DIR="$RUN_DIR"
export OWSYNC_BIN="$BIN_DIR/owsync"
export LEASE_SYNC_BIN="$BIN_DIR/lease-sync"
export TEST_CONFIG_FILE="$CONFIG_FILE"
export TEST_LOG_FILE="$LOG_FILE"

. "$REPO_ROOT/ha-cluster/files/ha-cluster.sh"

# The library asks uci for the dhcp pools of the VIP interfaces: one pool on
# br-lan, whose force option the test sets.
POOL_FORCE=1
uci() {
	case "$*" in
		"show dhcp") echo "dhcp.lan=dhcp" ;;
		"-q get dhcp.lan.interface") echo "br-lan" ;;
		"-q get dhcp.lan.force") echo "$POOL_FORCE" ;;
	esac
}

KEY="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

add_option() {
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CONFIG_FILE"
}

# Usage: write_config [name=value ...]
#   sync_method, key, encryption, dhcp_group, dhcp_files, lease_sync, peer,
#   vrrp_only, authoritative, owsync_bin, lease_sync_bin
write_config() {
	sync_method=
	key="$KEY"
	encryption=1
	dhcp_group=1
	dhcp_files=dhcp
	lease_sync=1
	peer=192.0.2.2
	vrrp_only=0
	authoritative=0
	owsync_bin=1
	lease_sync_bin=1
	for assignment in "$@"; do
		eval "$assignment"
	done

	: > "$CONFIG_FILE"
	: > "$LOG_FILE"
	rm -f "$OWSYNC_BIN" "$LEASE_SYNC_BIN" "$RUN_DIR"/*.conf

	if [ "$owsync_bin" -eq 1 ]; then
		printf '#!/bin/sh\n' > "$OWSYNC_BIN"
		chmod +x "$OWSYNC_BIN"
	fi
	if [ "$lease_sync_bin" -eq 1 ]; then
		printf '#!/bin/sh\n' > "$LEASE_SYNC_BIN"
		chmod +x "$LEASE_SYNC_BIN"
	fi

	add_option config TYPE global
	add_option config enabled 1
	[ -n "$sync_method" ] && add_option config sync_method "$sync_method"
	add_option config lease_sync "$lease_sync"
	add_option config sync_encryption "$encryption"
	[ -n "$key" ] && add_option config encryption_key "$key"

	add_option advanced TYPE advanced

	add_option dhcp TYPE sync_group
	add_option dhcp enabled "$dhcp_group"
	[ -n "$dhcp_files" ] && add_option dhcp config_files "$dhcp_files"

	add_option firewall TYPE sync_group
	add_option firewall enabled 0
	add_option firewall config_files firewall

	if [ -n "$peer" ]; then
		add_option peer1 TYPE peer
		add_option peer1 address "$peer"
		add_option peer1 vrrp_only "$vrrp_only"
	fi

	add_option main TYPE vrrp_instance
	add_option main vrid 51
	add_option main interface lan

	add_option vip_main TYPE vip
	add_option vip_main vrrp_instance main
	add_option vip_main interface br-lan
	add_option vip_main address 192.0.2.254
	add_option vip_main netmask 255.255.255.0

	# /etc/config/dhcp, which the stub serves from the same table
	add_option dnsmasq1 TYPE dnsmasq
	add_option dnsmasq1 authoritative "$authoritative"
	add_option dnsmasq1 confdir "$CONF_DIR"
}

fail() {
	echo "not ok - $1" >&2
	[ -s "$LOG_FILE" ] && sed 's/^/    log: /' "$LOG_FILE" >&2
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

logged() {
	grep -Fq -- "$1" "$LOG_FILE"
}

file_mode() {
	stat -c '%a' "$1"
}

generate() {
	ha_generate_owsync_conf || true
	ha_generate_lease_sync_conf || true
}

# ------------------------------------------------------------------
write_config
expect 'owsync is wanted with an enabled group and a peer' ha_owsync_wanted
expect 'lease sync is wanted with the switch on and a peer' ha_lease_sync_wanted
expect 'lease sync is active when lease-sync is installed' ha_lease_sync_active
expect 'a complete configuration passes validation' ha_validate_config
generate
expect 'owsync.conf is written' [ -s "$RUN_DIR/owsync.conf" ]
expect 'lease-sync.conf is written' [ -s "$RUN_DIR/lease-sync.conf" ]
expect 'owsync.conf is 0600' [ "$(file_mode "$RUN_DIR/owsync.conf")" = 600 ]
expect 'lease-sync.conf is 0600' [ "$(file_mode "$RUN_DIR/lease-sync.conf")" = 600 ]
expect 'owsync.conf carries the key' grep -Fxq "encryption_key=$KEY" "$RUN_DIR/owsync.conf"
expect 'owsync.conf lists the peer' grep -Fxq 'peer=192.0.2.2' "$RUN_DIR/owsync.conf"
expect 'owsync.conf includes the enabled group' grep -Fxq 'include=dhcp' "$RUN_DIR/owsync.conf"
refute 'owsync.conf leaves the disabled group out' grep -Fq 'include=firewall' "$RUN_DIR/owsync.conf"
expect 'lease-sync.conf is encrypted' grep -Fxq 'security_mode=encrypted' "$RUN_DIR/lease-sync.conf"
refute 'lease-sync.conf has no persist_interval' grep -Fq 'persist_interval' "$RUN_DIR/lease-sync.conf"
echo 'ok - a complete configuration runs both daemons with protected configs'

# ------------------------------------------------------------------
write_config peer=
refute 'owsync is not wanted without a peer' ha_owsync_wanted
refute 'lease sync is not wanted without a peer' ha_lease_sync_wanted
write_config peer= key=
expect 'no peer and no key passes validation' ha_validate_config
generate
refute 'no owsync.conf without a peer' [ -e "$RUN_DIR/owsync.conf" ]
refute 'no lease-sync.conf without a peer' [ -e "$RUN_DIR/lease-sync.conf" ]
echo 'ok - a cluster without a peer runs no sync daemon and needs no key'

write_config vrrp_only=1 key=
refute 'owsync is not wanted with a VRRP-only peer' ha_owsync_wanted
refute 'lease sync is not wanted with a VRRP-only peer' ha_lease_sync_wanted
expect 'a VRRP-only peer needs no key' ha_validate_config
echo 'ok - a vrrp_only peer does not count as a sync peer'

# ------------------------------------------------------------------
write_config sync_method=owsync
expect 'sync_method owsync passes validation' ha_validate_config
write_config sync_method=none
refute 'a sync_method other than owsync fails validation' ha_validate_config
expect 'the unsupported sync_method is reported' logged "sync_method 'none' is not supported"
echo 'ok - owsync is the only sync_method'

write_config dhcp_group=0
refute 'owsync is not wanted without an enabled group' ha_owsync_wanted
expect 'lease sync does not depend on the dhcp group' ha_lease_sync_active
generate
refute 'no owsync.conf without an enabled group' [ -e "$RUN_DIR/owsync.conf" ]
expect 'lease-sync.conf with the dhcp group disabled' [ -s "$RUN_DIR/lease-sync.conf" ]
echo 'ok - lease sync and the dhcp file group are independent'

write_config lease_sync=0
expect 'owsync is wanted with lease sync off' ha_owsync_wanted
refute 'lease sync is off' ha_lease_sync_wanted
generate
expect 'owsync.conf with lease sync off' [ -s "$RUN_DIR/owsync.conf" ]
refute 'no lease-sync.conf with lease sync off' [ -e "$RUN_DIR/lease-sync.conf" ]
echo 'ok - lease sync off leaves file sync alone'

# ------------------------------------------------------------------
write_config owsync_bin=0 lease_sync_bin=0
expect 'owsync stays wanted when it is not installed' ha_owsync_wanted
refute 'lease sync is not active when lease-sync is not installed' ha_lease_sync_active
generate
refute 'no owsync.conf when owsync is not installed' [ -e "$RUN_DIR/owsync.conf" ]
refute 'no lease-sync.conf when lease-sync is not installed' [ -e "$RUN_DIR/lease-sync.conf" ]
expect 'a missing owsync is reported' logged 'owsync is not installed'
expect 'a missing lease-sync is reported' logged 'lease-sync is not installed'
echo 'ok - a daemon that is not installed is reported and not started'

# ------------------------------------------------------------------
write_config key=
refute 'a missing key fails validation' ha_validate_config
generate
refute 'no owsync.conf without a key' [ -e "$RUN_DIR/owsync.conf" ]
refute 'no lease-sync.conf without a key' [ -e "$RUN_DIR/lease-sync.conf" ]
write_config key=abc123
refute 'a malformed key fails validation' ha_validate_config
write_config key= owsync_bin=0 lease_sync_bin=0
refute 'a missing key fails validation even when no daemon is installed' ha_validate_config
echo 'ok - sync without a usable key is refused, never downgraded'

write_config key= encryption=0
expect 'plain mode passes validation without a key' ha_validate_config
generate
expect 'owsync.conf is plain' grep -Fxq 'plain_mode=1' "$RUN_DIR/owsync.conf"
expect 'lease-sync.conf is plain' grep -Fxq 'security_mode=plain' "$RUN_DIR/lease-sync.conf"
refute 'plain owsync.conf has no key line' grep -Fq 'encryption_key=' "$RUN_DIR/owsync.conf"
echo 'ok - plain mode needs sync_encryption 0'

# ------------------------------------------------------------------
POOL_FORCE=0
write_config
refute 'a pool without force fails validation with lease sync active' ha_validate_config
expect 'the missing force is reported' logged "dhcp.lan.force must be '1'"
write_config lease_sync_bin=0
expect 'a pool without force passes when lease-sync is not installed' ha_validate_config
write_config lease_sync=0
expect 'a pool without force passes with lease sync off' ha_validate_config
POOL_FORCE=1
echo 'ok - the dhcp force check follows active lease sync'

# ------------------------------------------------------------------
write_config authoritative=1
expect 'authoritative with lease sync is a conflict' ha_dhcp_authoritative_conflict
expect 'validation still passes' ha_validate_config
expect 'the conflict is reported' logged 'dnsmasq is authoritative'
write_config authoritative=0
refute 'a non-authoritative dnsmasq is no conflict' ha_dhcp_authoritative_conflict
ha_validate_config
refute 'nothing is reported for a non-authoritative dnsmasq' logged 'dnsmasq is authoritative'
write_config authoritative=1 lease_sync=0
expect 'authoritative with the dhcp group synced is a conflict' ha_dhcp_authoritative_conflict
write_config authoritative=1 lease_sync=0 dhcp_group=0
refute 'authoritative without shared DHCP is no conflict' ha_dhcp_authoritative_conflict
write_config authoritative=1 lease_sync=0 dhcp_files=
refute 'an empty dhcp group is no conflict' ha_dhcp_authoritative_conflict
write_config authoritative=1 lease_sync=0 owsync_bin=0
refute 'owsync not installed is no conflict' ha_dhcp_authoritative_conflict
write_config authoritative=1 peer=
refute 'no peer is no conflict' ha_dhcp_authoritative_conflict
echo 'ok - an authoritative dnsmasq is reported when several nodes serve DHCP'

# ------------------------------------------------------------------
# The overlay is written once and dnsmasq restarts only when it changes.
: > "$DNSMASQ_RESTARTS"
ha_restart_dnsmasq() {
	echo restart >> "$DNSMASQ_RESTARTS"
}
restarts() {
	wc -l < "$DNSMASQ_RESTARTS" | tr -d ' '
}
# Its status is that of its last test, non-zero when nothing had to restart
configure_dnsmasq() {
	ha_configure_dnsmasq || true
}

write_config
configure_dnsmasq
OVERLAY="$CONF_DIR/ha-cluster.conf"
expect 'the overlay is written with lease sync active' [ -s "$OVERLAY" ]
expect 'the overlay enables script-on-renewal' grep -Fxq 'script-on-renewal' "$OVERLAY"
refute 'the overlay does not make dnsmasq authoritative' grep -Fq 'dhcp-authoritative' "$OVERLAY"
expect 'dnsmasq restarts for a new overlay' [ "$(restarts)" = 1 ]
configure_dnsmasq
expect 'dnsmasq does not restart for an unchanged overlay' [ "$(restarts)" = 1 ]
refute 'no temporary overlay is left behind' [ -e "$CONF_DIR/.ha-cluster.conf.new" ]

printf '# old\ndhcp-authoritative\nscript-on-renewal\n' > "$OVERLAY"
configure_dnsmasq
refute 'an overlay from an older release is replaced' grep -Fq 'dhcp-authoritative' "$OVERLAY"
expect 'dnsmasq restarts for a replaced overlay' [ "$(restarts)" = 2 ]

write_config lease_sync_bin=0
configure_dnsmasq
refute 'the overlay is removed when lease sync is not active' [ -e "$OVERLAY" ]
expect 'dnsmasq restarts for a removed overlay' [ "$(restarts)" = 3 ]
configure_dnsmasq
expect 'dnsmasq does not restart without an overlay' [ "$(restarts)" = 3 ]
echo 'ok - the dnsmasq overlay follows active lease sync and restarts dnsmasq only on change'

echo 'All ha-cluster sync gating tests passed.'
