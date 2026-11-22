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
		0|off|false|no|disabled) resolved_bool=0 ;;
		# As OpenWrt's config_get_bool: any other value is the default
		*) resolved_bool="${4:-0}" ;;
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
# br-lan, whose options the test sets, and one on an interface without VIP.
POOL_FORCE=1
POOL_IGNORE=
POOL_DHCPV4=
uci() {
	case "$*" in
		"show dhcp") printf 'dhcp.guest=dhcp\ndhcp.lan=dhcp\n' ;;
		"-q get dhcp.guest.interface") echo "br-guest" ;;
		"-q get dhcp.lan.interface") echo "br-lan" ;;
		"-q get dhcp.lan.force") echo "$POOL_FORCE" ;;
		"-q get dhcp.lan.ignore") echo "$POOL_IGNORE" ;;
		"-q get dhcp.lan.dhcpv4") echo "$POOL_DHCPV4" ;;
		"-q get kea.dhcp4") echo "$KEA4_SECTION" ;;
		"-q get kea.dhcp4.disabled") echo "$KEA4_DISABLED" ;;
		"-q get kea.dhcp6") echo "$KEA6_SECTION" ;;
		"-q get kea.dhcp6.disabled") echo "$KEA6_DISABLED" ;;
	esac
}
# /etc/config/kea: no section for either daemon unless a test says so
KEA4_SECTION=
KEA4_DISABLED=
KEA6_SECTION=
KEA6_DISABLED=

KEY="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

add_option() {
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CONFIG_FILE"
}

# Usage: write_config [name=value ...]
#   sync_method, key, encryption, dhcp_group, dhcp_files, lease_sync, peer,
#   vrrp_only, authoritative, owsync_bin, lease_sync_bin, backend
write_config() {
	sync_method=
	backend=
	cluster_enabled=1
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
	add_option config enabled "$cluster_enabled"
	[ -n "$sync_method" ] && add_option config sync_method "$sync_method"
	[ -n "$backend" ] && add_option config dhcp_backend "$backend"
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
write_config key= encryption=maybe
refute 'a value of sync_encryption that is no boolean does not mean plain mode' ha_validate_config
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

# ------------------------------------------------------------------
# Kea as the DHCP server: it replicates its leases itself, so nothing of
# lease-sync runs, and what dnsmasq needs for lease sync is not asked for.
KEA_DHCP4_BIN="$BIN_DIR/kea-dhcp4"
KEA_DHCP6_BIN="$BIN_DIR/kea-dhcp6"
rm -f "$KEA_DHCP4_BIN" "$KEA_DHCP6_BIN"

write_config
refute 'dnsmasq is the backend unless said otherwise' ha_dhcp_backend_is_kea
write_config backend=dnsmasq
expect 'lease sync is wanted with the dnsmasq backend named' ha_lease_sync_wanted
configure_dnsmasq
expect 'the overlay is there before the change to Kea' [ -s "$OVERLAY" ]
before="$(restarts)"

POOL_FORCE=0
write_config backend=kea
expect 'the backend is kea' ha_dhcp_backend_is_kea
refute 'lease sync is not wanted with Kea' ha_lease_sync_wanted
refute 'lease sync is not active with Kea' ha_lease_sync_active
expect 'file sync is still wanted with Kea' ha_owsync_wanted
expect 'validation passes without the dhcp force of lease sync' ha_validate_config
refute 'no missing force is reported' logged "force must be '1'"
expect 'the unused lease_sync switch is mentioned' logged 'lease_sync is not used with Kea as the DHCP server'
expect 'a missing Kea is reported' logged 'neither kea-dhcp4 nor kea-dhcp6 is installed'
expect 'a dnsmasq pool on the VIP interface is reported' \
	logged "dnsmasq still answers DHCPv4 on interface 'br-lan' (dhcp.lan)"
refute 'a pool on an interface without VIP is not' logged '(dhcp.guest)'
POOL_FORCE=1
generate
refute 'no lease-sync.conf is written with Kea' [ -e "$RUN_DIR/lease-sync.conf" ]
expect 'owsync.conf is still written with Kea' [ -s "$RUN_DIR/owsync.conf" ]
configure_dnsmasq
refute 'the overlay is removed with Kea' [ -e "$OVERLAY" ]
expect 'dnsmasq restarts once for the removed overlay' [ "$(restarts)" = "$((before + 1))" ]
echo 'ok - with Kea nothing of lease-sync runs and its dnsmasq needs are not checked'

printf '#!/bin/sh\n' > "$KEA_DHCP6_BIN"
chmod +x "$KEA_DHCP6_BIN"
POOL_DHCPV4=disabled
write_config backend=kea lease_sync=0
expect 'validation passes' ha_validate_config
refute 'an installed Kea daemon is not reported missing' logged 'neither kea-dhcp4 nor kea-dhcp6'
refute 'a pool with DHCPv4 off is not reported' logged 'still answers DHCPv4'
refute 'a lease_sync switch that is off is not mentioned' logged 'lease_sync is not used'
POOL_DHCPV4=
POOL_IGNORE=1
write_config backend=kea
ha_validate_config
refute 'an ignored pool is not reported' logged 'still answers DHCPv4'
POOL_IGNORE=
rm -f "$KEA_DHCP6_BIN"
echo 'ok - with Kea only what is really in the way is reported'

write_config backend=kea authoritative=1
refute 'an authoritative dnsmasq is no conflict with Kea' ha_dhcp_authoritative_conflict
ha_validate_config
refute 'and is not reported' logged 'dnsmasq is authoritative'
write_config backend=kea key= dhcp_group=0
expect 'Kea without file sync needs no key' ha_validate_config
write_config backend=kea key=
refute 'file sync still needs its key with Kea' ha_validate_config
echo 'ok - with Kea the authoritative warning is off and the key is asked for file sync only'

# ------------------------------------------------------------------
# The config file of an enabled Kea daemon: the high-availability hook and
# the socket retries are looked for, in what is not a comment
KEA_CONF_DIR="$TEST_ROOT/kea"
mkdir -p "$KEA_CONF_DIR"
kea_conf() {
	printf '%s\n' "$@" > "$KEA_CONF_DIR/kea-dhcp4.conf"
}
HOOK='{ "library": "/usr/lib/kea/hooks/libdhcp_ha.so" }'
RETRIES='"service-sockets-max-retries": 60,'

KEA4_SECTION=service
KEA4_DISABLED=0
kea_conf "$RETRIES" "$HOOK"
write_config backend=kea
expect 'validation passes' ha_validate_config
refute 'a config with the hook is not reported' logged 'high-availability hook'
refute 'a config with retries is not reported' logged 'service-sockets-max-retries'

kea_conf "$RETRIES"
write_config backend=kea
expect 'a config without the hook still passes validation' ha_validate_config
expect 'the missing hook is reported' logged "kea-dhcp4.conf does not load Kea's high-availability hook"
refute 'the retries are not' logged 'service-sockets-max-retries'

kea_conf "$HOOK"
write_config backend=kea
ha_validate_config
expect 'missing socket retries are reported' logged 'kea-dhcp4.conf sets no service-sockets-max-retries'
refute 'the hook is not' logged 'high-availability hook'

kea_conf '"service-sockets-max-retries": 0,' "$HOOK"
write_config backend=kea
ha_validate_config
expect 'socket retries set to none are reported' logged 'kea-dhcp4.conf sets no service-sockets-max-retries'

kea_conf '"service-sockets-max-retries" : 5' "$HOOK"
write_config backend=kea
ha_validate_config
refute 'retries written with spaces are found' logged 'service-sockets-max-retries'

kea_conf "  // $RETRIES" "# $HOOK"
write_config backend=kea
ha_validate_config
expect 'a hook named in a comment only is reported as missing' logged 'high-availability hook'
expect 'retries named in a comment only are reported as missing' logged 'sets no service-sockets-max-retries'

kea_conf '"url": "http://192.0.2.1:8001/",' "$RETRIES" "$HOOK"
write_config backend=kea
ha_validate_config
refute 'a line with // inside a value is not taken for a comment' logged 'kea-dhcp4.conf'

# Every url of the hook needs a port: Kea accepts one without and then
# cannot be found by its partner
kea_conf "$RETRIES" "$HOOK" '"url": "http://192.0.2.1:8001/",' '{ "name": "b", "url": "http://[2001:db8::2]:8001/" }'
write_config backend=kea
ha_validate_config
refute 'urls with a port are not reported' logged 'without a port'

kea_conf "$RETRIES" "$HOOK" '"url": "http://192.0.2.1:8001/",' '"url": "http://192.0.2.2/"'
write_config backend=kea
ha_validate_config
expect 'a url without a port is reported, and named' logged "has the url 'http://192.0.2.2/' without a port"

kea_conf "$RETRIES" "$HOOK" '"url": "http://[2001:db8::8001]/"'
write_config backend=kea
ha_validate_config
expect 'the end of an IPv6 address is not taken for a port' logged "has the url 'http://[2001:db8::8001]/' without a port"

kea_conf "$RETRIES" "$HOOK" '"url": "http://192.0.2.2"'
write_config backend=kea
ha_validate_config
expect 'nor is a port assumed for a url that ends with the address' logged "has the url 'http://192.0.2.2' without a port"

kea_conf "$RETRIES" "$HOOK" '  // "url": "http://192.0.2.2/",' '"url": "http://192.0.2.2:8001"'
write_config backend=kea
ha_validate_config
refute 'a url in a comment is not looked at' logged 'without a port'

rm -f "$KEA_CONF_DIR/kea-dhcp4.conf"
write_config backend=kea
ha_validate_config
expect 'a missing config file of an enabled daemon is reported' logged 'kea-dhcp4 is enabled but'

kea_conf '{}'
KEA4_DISABLED=1
write_config backend=kea
ha_validate_config
refute 'the config of a disabled daemon is not looked at' logged 'kea-dhcp4.conf'
KEA4_SECTION=
KEA4_DISABLED=
write_config backend=kea
ha_validate_config
refute 'nor that of a daemon without a section' logged 'kea-dhcp4.conf'

KEA4_SECTION=service
write_config
ha_validate_config
refute 'with dnsmasq the Kea config is not looked at' logged 'kea-dhcp4.conf'

KEA4_SECTION=
KEA6_SECTION=service
printf '%s\n' '{}' > "$KEA_CONF_DIR/kea-dhcp6.conf"
write_config backend=kea
ha_validate_config
expect 'kea-dhcp6 has its own file' logged "kea-dhcp6.conf does not load Kea's high-availability hook"
refute 'and kea-dhcp4 is left alone' logged 'kea-dhcp4.conf'
KEA6_SECTION=
echo 'ok - the config of an enabled Kea daemon is checked for the hook and for socket retries'

# ------------------------------------------------------------------
# An interface has come up: a Kea daemon whose config names the device reads
# its config again, once it takes the signal for that
HA_PROC_DIR="$TEST_ROOT/proc"
HA_SYS_NET_DIR="$TEST_ROOT/sys-net"
HA_KEA_DEVICE_DIR="$RUN_DIR/kea-devices"
SIGNALS="$TEST_ROOT/signals"
SLEEPS="$TEST_ROOT/sleeps"
KEA4_PIDS=
KEA6_PIDS=
READY_AFTER=
pidof() {
	case "$1" in
		kea-dhcp4) [ -z "$KEA4_PIDS" ] || echo "$KEA4_PIDS" ;;
		kea-dhcp6) [ -z "$KEA6_PIDS" ] || echo "$KEA6_PIDS" ;;
	esac
}
kill() {
	echo "$*" >> "$SIGNALS"
}
# SigCgt of a Kea that handles SIGHUP (as read on a running kea-dhcp4), and
# of one that does not yet
CATCHES=0000000000004003
NOT_YET=0000000000004002
process() {
	mkdir -p "$HA_PROC_DIR/$1"
	printf 'Name:\tkea-dhcp4\nSigCgt:\t%s\n' "$2" > "$HA_PROC_DIR/$1/status"
}
# Each second waited is counted; after READY_AFTER of them process 4001
# starts to take the signal
sleep() {
	echo "$1" >> "$SLEEPS"
	[ -n "$READY_AFTER" ] || return 0
	[ "$(grep -c . "$SLEEPS")" -lt "$READY_AFTER" ] || process 4001 "$CATCHES"
}
# The index of a device, as the kernel shows it
device_index() {
	mkdir -p "$HA_SYS_NET_DIR/$1"
	echo "$2" > "$HA_SYS_NET_DIR/$1/ifindex"
}
# ifup of an interface on the device it had before
same_device_up() {
	: > "$SIGNALS"
	: > "$SLEEPS"
	: > "$LOG_FILE"
	ha_kea_device_up "$@"
	wait
}
# ifup of an interface whose device netifd has made anew: a new index
NEXT_INDEX=10
device_up() {
	NEXT_INDEX=$((NEXT_INDEX + 1))
	[ -z "${2:-}" ] || device_index "$2" "$NEXT_INDEX"
	same_device_up "$@"
}
signalled() {
	grep -qx -- "-HUP $1" "$SIGNALS"
}
no_signal() {
	[ ! -s "$SIGNALS" ]
}

rm -rf "$HA_PROC_DIR"
KEA4_SECTION=service
KEA4_PIDS=4001
process 4001 "$CATCHES"
kea_conf '"interfaces": [ "br-lan" ],'
write_config backend=kea

device_up lan br-lan
expect 'the daemon that listens on the device is signalled' signalled 4001
expect 'and the log says why' logged "Interface 'lan' (br-lan) is up: kea-dhcp4 told to read its config again"
[ ! -s "$SLEEPS" ] || fail 'a daemon that takes the signal was waited for'

device_up wan eth9
expect 'a device the config does not name is no reason' no_signal
device_up lan br-la
expect 'nor is a device whose name is the beginning of a named one' no_signal
# An empty string in the config is not the name of a device
kea_conf '"interfaces": [ "br-lan" ],' '"boot-file-name": "",'
device_up lan ''
expect 'nor an event without a device' no_signal

kea_conf '"interfaces": [ "br-lan/192.0.2.1" ],'
device_up lan br-lan
expect 'a device named with an address is found' signalled 4001

kea_conf '"interfaces": [ "*" ],'
device_up wan eth9
expect 'a config that listens everywhere is reloaded for any device' signalled 4001

kea_conf '// "interfaces": [ "br-lan" ],' '"interfaces": [ "eth7" ],'
device_up lan br-lan
expect 'a device named in a comment only is no reason' no_signal

kea_conf '"interfaces": [ "br-lan" ],'
write_config
device_up lan br-lan
expect 'with dnsmasq as the DHCP server Kea is left alone' no_signal
write_config backend=kea cluster_enabled=0
device_up lan br-lan
expect 'and so it is in a cluster that is switched off' no_signal
write_config backend=kea

KEA4_PIDS=
device_up lan br-lan
expect 'a daemon that does not run gets nothing' no_signal
[ ! -s "$LOG_FILE" ] || fail 'a daemon that does not run was logged about'

# kea-dhcp6 has its own config and is asked on its own
KEA4_PIDS=4001
KEA6_PIDS=6001
process 6001 "$CATCHES"
printf '%s\n' '"interfaces": [ "br-guest" ],' > "$KEA_CONF_DIR/kea-dhcp6.conf"
device_up guest br-guest
expect 'the daemon whose config names the device is signalled' signalled 6001
refute 'and the other one is not' signalled 4001
device_up lan br-lan
expect 'each for its own device' signalled 4001
refute 'each for its own device only' signalled 6001
KEA6_PIDS=
rm -f "$KEA_CONF_DIR/kea-dhcp6.conf"
echo 'ok - a Kea daemon reads its config again when a device it listens on has come up'

# A Kea in its first moments does not handle SIGHUP and would be ended by it
process 4001 "$NOT_YET"
READY_AFTER=3
device_up lan br-lan
expect 'the signal is sent once the daemon takes it' signalled 4001
[ "$(grep -c . "$SLEEPS")" -eq 3 ] || fail "waited $(grep -c . "$SLEEPS") seconds for a daemon ready after 3"

process 4001 "$NOT_YET"
READY_AFTER=
device_up lan br-lan
expect 'a daemon that never takes the signal is not sent it' no_signal
[ "$(grep -c . "$SLEEPS")" -eq 10 ] || fail "gave up after $(grep -c . "$SLEEPS") seconds, not 10"
expect 'and that is reported' logged 'kea-dhcp4 (pid 4001) takes no reload signal'

rm -rf "$HA_PROC_DIR/4001"
device_up lan br-lan
expect 'a daemon that is gone is not signalled' no_signal
[ ! -s "$LOG_FILE" ] || fail 'a daemon that is gone was logged about'
[ ! -s "$SLEEPS" ] || fail 'a daemon that is gone was waited for'
echo 'ok - the reload signal waits for a Kea that has just started and is never sent blind'

# Only a device that is another one than at its last ifup is a reason
process 4001 "$CATCHES"
rm -rf "$HA_KEA_DEVICE_DIR" "$HA_SYS_NET_DIR"
device_index br-lan 7
same_device_up lan br-lan
expect 'the first ifup of a device counts as a new device' signalled 4001
[ "$(cat "$HA_KEA_DEVICE_DIR/br-lan")" = "7" ] || fail 'the index of the device was not remembered'
same_device_up lan br-lan
expect 'an ifup on the same device leaves Kea alone' no_signal
device_index br-lan 12
same_device_up lan br-lan
expect 'the device made anew, with a new index, is a reason again' signalled 4001
same_device_up lan br-lan
expect 'and once is enough' no_signal

device_index br-guest 13
printf '%s\n' '"interfaces": [ "br-guest" ],' > "$KEA_CONF_DIR/kea-dhcp6.conf"
KEA6_PIDS=6001
same_device_up guest br-guest
expect 'each device has its own index remembered' signalled 6001
same_device_up lan br-lan
expect 'and the ifup of one does not stand for another' no_signal
KEA6_PIDS=
rm -f "$KEA_CONF_DIR/kea-dhcp6.conf"

rm -rf "$HA_SYS_NET_DIR/br-lan"
same_device_up lan br-lan
expect 'a device that is gone again is no reason' no_signal
[ "$(cat "$HA_KEA_DEVICE_DIR/br-lan")" = "12" ] || fail 'the index of a device that is gone was overwritten'

device_index br-lan 14
KEA4_PIDS=
same_device_up lan br-lan
expect 'no daemon runs: nothing is signalled' no_signal
KEA4_PIDS=4001
same_device_up lan br-lan
expect 'a Kea started after that ifup opened its sockets on that device' no_signal

rm -rf "$HA_KEA_DEVICE_DIR"
write_config backend=kea cluster_enabled=0
same_device_up lan br-lan
[ ! -e "$HA_KEA_DEVICE_DIR/br-lan" ] || fail 'an index was remembered in a cluster that is switched off'
write_config
same_device_up lan br-lan
[ ! -e "$HA_KEA_DEVICE_DIR/br-lan" ] || fail 'an index was remembered with dnsmasq as the DHCP server'
write_config backend=kea
# A name that would lead out of both directories, with an index to be found
mkdir -p "$TEST_ROOT/escape"
echo 99 > "$TEST_ROOT/escape/ifindex"
same_device_up lan ../escape
[ ! -e "$RUN_DIR/escape" ] || fail 'a device name with a slash left the directory'
KEA4_PIDS=
KEA4_SECTION=
echo 'ok - Kea is asked to reload only for a device that is another one than at its last ifup'

# ------------------------------------------------------------------
# The ports of Kea's high availability, from the "url"s of its config
KEA4_SECTION=service
KEA4_DISABLED=0
kea_conf '{ "name": "a", "url": "http://192.0.2.1:8001/", "role": "primary" }, { "name": "b", "url": "http://192.0.2.2:8001/" }' \
	'  "url" : "https://[2001:db8::2]:8443/ha",' \
	'  // "url": "http://192.0.2.9:9999/",' \
	'# "url": "http://192.0.2.9:9998/",' \
	'  "url": "http://192.0.2.3/",' \
	'  "library-url": "http://192.0.2.4:7777/",' \
	'  "url": "http://192.0.2.5:123456/"'
ports="$(ha_kea_ha_ports | tr '\n' ' ')"
[ "$ports" = "8001 8443 " ] || fail "ports of the Kea config: '$ports'"

KEA6_SECTION=service
printf '%s\n' '"url": "http://192.0.2.1:8002/",' '"url": "http://192.0.2.2:8001/"' > "$KEA_CONF_DIR/kea-dhcp6.conf"
ports="$(ha_kea_ha_ports | tr '\n' ' ')"
[ "$ports" = "8001 8002 8443 " ] || fail "ports of both Kea configs: '$ports'"
KEA4_DISABLED=1
ports="$(ha_kea_ha_ports | tr '\n' ' ')"
[ "$ports" = "8001 8002 " ] || fail "ports with kea-dhcp4 disabled: '$ports'"
KEA4_DISABLED=0
rm -f "$KEA_CONF_DIR/kea-dhcp4.conf" "$KEA_CONF_DIR/kea-dhcp6.conf"
[ -z "$(ha_kea_ha_ports)" ] || fail 'ports without a Kea config'
KEA6_SECTION=
echo 'ok - the ports of Kea high availability are those of the urls in the config of each enabled daemon'

# ------------------------------------------------------------------
# What the firewall must let in, as a description of rules. netifd answers
# nothing here: an interface is the device it is named as
mkdir -p "$FAKE_ROOT/lib/functions"
printf 'network_get_device() { return 1; }\n' > "$FAKE_ROOT/lib/functions/network.sh"
OWN_BY_ROUTE=
ip() {
	[ -n "$OWN_BY_ROUTE" ] || return 1
	echo "$4 dev eth0 src $OWN_BY_ROUTE uid 0"
}
rules() {
	ha_firewall_rules > "$TEST_ROOT/rules" 2>/dev/null
}
has() {
	grep -qxF -- "$1" "$TEST_ROOT/rules"
}
lacks() {
	! grep -qF -- "$1" "$TEST_ROOT/rules"
}
shown() {
	_ha_fw_as_shown < "$TEST_ROOT/rules" > "$TEST_ROOT/shown"
	grep -qxF -- "$1" "$TEST_ROOT/shown"
}

# A Kea config with ports lies about; with dnsmasq as the DHCP server it
# opens nothing
KEA4_SECTION=service
kea_conf '"url": "http://192.0.2.1:8001/",'
write_config
add_option peer1 source_address 192.0.2.1
expect 'the rules can be described' rules
expect 'VRRP on the device of the instance' has 'O|ha_cluster_vrrp_1|device|lan'
expect 'named after it' has 'O|ha_cluster_vrrp_1|name|HA-Cluster-VRRP-lan'
expect 'coming in' has 'O|ha_cluster_vrrp_1|direction|in'
expect 'protocol 112' has 'L|ha_cluster_vrrp_1|proto|112'
expect 'no AH without an instance that uses it' lacks '|proto|51'
expect 'owsync from this node' has 'L|ha_cluster_owsync|src_ip|192.0.2.1'
expect 'and from the peer' has 'L|ha_cluster_owsync|src_ip|192.0.2.2'
expect 'on its port' has 'L|ha_cluster_owsync|dest_port|4321'
expect 'over TCP' has 'L|ha_cluster_owsync|proto|tcp'
expect 'lease-sync over UDP' has 'L|ha_cluster_lease_sync|proto|udp'
expect 'on its port' has 'L|ha_cluster_lease_sync|dest_port|5378'
expect 'ping from the peer' has 'L|ha_cluster_ping|src_ip|192.0.2.2'
expect 'as an echo request' has 'L|ha_cluster_ping|icmp_type|echo-request'
expect 'no rule for Kea with dnsmasq' lacks 'ha_cluster_kea'
KEA4_SECTION=
rm -f "$KEA_CONF_DIR/kea-dhcp4.conf"
expect 'every rule accepts' has 'O|ha_cluster_owsync|target|ACCEPT'
expect 'from any zone' has 'O|ha_cluster_owsync|src|*'
expect 'a list reads as uci shows it' shown "ha_cluster_owsync.src_ip='192.0.2.1' '192.0.2.2'"
expect 'an option too' shown "ha_cluster_owsync.name='HA-Cluster-owsync'"
expect 'and a section' shown 'ha_cluster_owsync=rule'

add_option config sync_port 4444
add_option advanced lease_sync_port 5555
rules
expect 'the configured port of owsync' has 'L|ha_cluster_owsync|dest_port|4444'
expect 'the configured port of lease-sync' has 'L|ha_cluster_lease_sync|dest_port|5555'

write_config lease_sync=0 dhcp_group=0
add_option peer1 source_address 192.0.2.1
rules
expect 'no rule for owsync without work for it' lacks 'ha_cluster_owsync'
expect 'no rule for lease-sync without work for it' lacks 'ha_cluster_lease_sync'
expect 'ping stays' has 'L|ha_cluster_ping|src_ip|192.0.2.2'

write_config vrrp_only=1
add_option peer1 source_address 192.0.2.1
rules
expect 'a peer that only speaks VRRP gets no sync rule' lacks 'ha_cluster_owsync'
expect 'and is pinged' has 'L|ha_cluster_ping|src_ip|192.0.2.2'

# A peer that syncs next to one that only speaks VRRP
write_config
add_option peer1 source_address 192.0.2.1
add_option box TYPE peer
add_option box address 192.0.2.3
add_option box source_address 192.0.2.1
add_option box vrrp_only 1
rules
expect 'the peer that syncs is in the sync rules' has 'L|ha_cluster_owsync|src_ip|192.0.2.2'
refute 'the VRRP-only peer is not in the rule of owsync' has 'L|ha_cluster_owsync|src_ip|192.0.2.3'
refute 'nor in that of lease-sync' has 'L|ha_cluster_lease_sync|src_ip|192.0.2.3'
expect 'and is pinged like the other' has 'L|ha_cluster_ping|src_ip|192.0.2.3'

# Kea as the DHCP server: its ports, and no lease-sync
KEA4_SECTION=service
kea_conf '"url": "http://192.0.2.1:8001/",' '"url": "http://192.0.2.2:8001/"'
write_config backend=kea
add_option peer1 source_address 192.0.2.1
rules
expect 'the port of Kea high availability' has 'L|ha_cluster_kea|dest_port|8001'
expect 'from the nodes' has 'L|ha_cluster_kea|src_ip|192.0.2.2'
expect 'no rule for lease-sync with Kea' lacks 'ha_cluster_lease_sync'
rm -f "$KEA_CONF_DIR/kea-dhcp4.conf"
rules
expect 'no Kea rule without a port' lacks 'ha_cluster_kea'
KEA4_SECTION=

# More instances, one of them with AH, next to 'main' on 'lan': a rule per
# device, the devices in the order of their names
write_config
add_option one TYPE vrrp_instance
add_option one interface eth1
add_option one auth_type AH
add_option two TYPE vrrp_instance
add_option two interface br-lan
add_option three TYPE vrrp_instance
add_option three interface eth1
add_option peer1 source_address 192.0.2.1
rules
expect 'devices sorted by name' has 'O|ha_cluster_vrrp_1|device|br-lan'
expect 'each once' has 'O|ha_cluster_vrrp_2|device|eth1'
expect 'the last one' has 'O|ha_cluster_vrrp_3|device|lan'
expect 'no further rule for a device named twice' lacks 'ha_cluster_vrrp_4'
expect 'AH on the device whose instance uses it' has 'L|ha_cluster_vrrp_2|proto|51'
refute 'and not on another' has 'L|ha_cluster_vrrp_1|proto|51'
refute 'nor on the third' has 'L|ha_cluster_vrrp_3|proto|51'

# This node's own address: source_address of the peer, bind_address, the
# kernel's route; without any the rules are not described
write_config
add_option config bind_address 192.0.2.7
rules
expect 'bind_address is this node' has 'L|ha_cluster_owsync|src_ip|192.0.2.7'
write_config
OWN_BY_ROUTE=192.0.2.9
rules
expect 'the address the kernel routes with is this node' has 'L|ha_cluster_owsync|src_ip|192.0.2.9'
OWN_BY_ROUTE=
write_config
refute 'without an own address the rules are not described' rules
[ "$_ha_fw_own_unknown" = " 192.0.2.2" ] || fail "the peer without an own address is not named: '$_ha_fw_own_unknown'"

# Values that would not be an address, a device or a port make no rule
write_config peer=node2.example
add_option bad TYPE vrrp_instance
add_option bad interface 'br-lan; drop'
rules
expect 'a peer named by a host name gets no rule' lacks 'node2.example'
expect 'and a device that is no device name none' lacks 'drop'
expect 'both are reported' logged "'node2.example' is no IP address"
expect 'both are reported' logged "is no device name"
write_config
add_option peer1 source_address 192.0.2.1
add_option config sync_port '4321; drop'
rules
expect 'a port that is no number makes no rule' lacks 'ha_cluster_owsync'
unset -f ip
echo 'ok - the firewall rules of the cluster are described from the instances, the peers and the daemons that have work'

write_config backend=isc
refute 'an unknown backend fails validation' ha_validate_config
expect 'the unknown backend is named' logged "dhcp_backend 'isc' is not supported"
echo 'ok - an unknown DHCP backend is refused'

echo 'All ha-cluster sync gating tests passed.'
