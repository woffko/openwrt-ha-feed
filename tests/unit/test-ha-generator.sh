#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
TEST_ROOT="$(mktemp -d)"
FAKE_ROOT="$TEST_ROOT/root"
CONFIG_FILE="$TEST_ROOT/config.tsv"
LOG_FILE="$TEST_ROOT/ha.log"
RUN_DIR="$TEST_ROOT/run"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_ROOT/lib/config" "$FAKE_ROOT/lib/functions" \
	"$FAKE_ROOT/usr/lib/ha-cluster" "$FAKE_ROOT/bin" "$RUN_DIR"

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

cat > "$FAKE_ROOT/lib/functions/network.sh" <<'EOF'
network_get_device() {
	local destination="$1"
	local requested_interface="$2"
	eval "$destination='$requested_interface'"
}
EOF

cat > "$FAKE_ROOT/usr/lib/ha-cluster/check-dataplane" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$FAKE_ROOT/bin/true" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKE_ROOT/usr/lib/ha-cluster/check-dataplane" "$FAKE_ROOT/bin/true"

export IPKG_INSTROOT="$FAKE_ROOT"
export HA_CLUSTER_RUN_DIR="$RUN_DIR"
export TEST_CONFIG_FILE="$CONFIG_FILE"
export TEST_LOG_FILE="$LOG_FILE"

. "$REPO_ROOT/ha-cluster/files/ha-cluster.sh"

add_option() {
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CONFIG_FILE"
}

write_config() {
	variant="${1:-valid}"
	: > "$CONFIG_FILE"
	: > "$LOG_FILE"

	add_option config TYPE global
	add_option config enabled 1
	add_option config node_priority 200
	add_option config vrrp_transport multicast
	add_option config sync_method none

	add_option advanced TYPE advanced
	add_option advanced max_auto_priority 0
	add_option advanced enable_notifications 0

	add_option dhcp TYPE service
	add_option dhcp sync_leases 0

	add_option peer1 TYPE peer
	add_option peer1 address 192.0.2.2

	add_option main TYPE vrrp_instance
	add_option main vrid 51
	add_option main interface lan
	add_option main priority 200
	add_option main nopreempt 0
	add_option main advert_int 1
	add_option main track_script check_dp
	add_option main track_script check_legacy
	[ "$variant" = unknown_track ] && add_option main track_script missing_check

	add_option guest TYPE vrrp_instance
	add_option guest vrid 52
	add_option guest interface lan
	add_option guest priority 200
	add_option guest nopreempt 0
	add_option guest advert_int 1

	add_option vip_main TYPE vip
	add_option vip_main enabled 1
	add_option vip_main vrrp_instance main
	add_option vip_main interface br-lan
	add_option vip_main address 192.0.2.254
	add_option vip_main netmask 255.255.255.0
	add_option vip_main address6 2001:db8::fe
	add_option vip_main prefix6 64

	add_option vip_guest TYPE vip
	add_option vip_guest enabled 1
	add_option vip_guest vrrp_instance guest
	add_option vip_guest interface br-guest
	add_option vip_guest address 198.51.100.254
	add_option vip_guest netmask 255.255.255.0
	add_option vip_guest address6 2001:db8:1::fe
	add_option vip_guest prefix6 64

	add_option check_dp TYPE script
	add_option check_dp check_type dataplane
	if [ "$variant" = unknown_instance ]; then
		add_option check_dp vrrp_instance 'main missing_instance'
	elif [ "$variant" != missing_instance ]; then
		add_option check_dp vrrp_instance 'main guest'
	fi
	add_option check_dp interface bond0.20
	add_option check_dp bond bond0
	add_option check_dp min_lacp_members 1
	add_option check_dp min_success "$([ "$variant" = excessive_min ] && echo 3 || echo 1)"
	add_option check_dp probe_timeout 1
	[ "$variant" != missing_target ] && add_option check_dp target 192.0.2.10
	[ "$variant" != missing_target ] && add_option check_dp target 192.0.2.11
	add_option check_dp interval 2
	add_option check_dp timeout "$([ "$variant" = short_timeout ] && echo 2 || echo 3)"
	add_option check_dp weight "$([ "$variant" = excessive_weight ] && echo 254 || echo 0)"
	add_option check_dp rise 5
	add_option check_dp fall 3

	add_option check_legacy TYPE script
	add_option check_legacy check_type command
	add_option check_legacy script "$([ "$variant" = relative_command ] && echo bin/true || echo /bin/true)"
	add_option check_legacy interval 5
}

expect_validation_failure() {
	variant="$1"
	label="$2"
	write_config "$variant"
	if ha_validate_config; then
		echo "not ok - $label" >&2
		exit 1
	fi
	echo "ok - $label"
}

write_config valid
if ! ha_validate_config; then
	echo 'not ok - valid managed checks failed validation' >&2
	cat "$LOG_FILE" >&2
	exit 1
fi
echo 'ok - valid managed and legacy checks pass validation'

set +e
ha_generate_keepalived_conf
generate_status=$?
set -e
[ "$generate_status" -eq 0 ] || {
	echo "not ok - configuration generation failed with status $generate_status" >&2
	exit 1
}
CONF="$RUN_DIR/keepalived.conf"
[ -s "$CONF" ] || {
	echo 'not ok - keepalived.conf was not generated' >&2
	exit 1
}

grep -Fq 'vrrp_script check_dp {' "$CONF"
grep -Fq 'script "/usr/lib/ha-cluster/check-dataplane check_dp"' "$CONF"
grep -Fq 'vrrp_script check_legacy {' "$CONF"
echo 'ok - dataplane command is synthesized and legacy command is preserved'

main_block=$(sed -n '/^vrrp_instance main {/,/^}/p' "$CONF")
main_v6_block=$(sed -n '/^vrrp_instance main_v6 {/,/^}/p' "$CONF")
guest_block=$(sed -n '/^vrrp_instance guest {/,/^}/p' "$CONF")
guest_v6_block=$(sed -n '/^vrrp_instance guest_v6 {/,/^}/p' "$CONF")

[ "$(printf '%s\n' "$main_block" | grep -c '^        check_dp$')" -eq 1 ]
[ "$(printf '%s\n' "$main_v6_block" | grep -c '^        check_dp$')" -eq 1 ]
[ "$(printf '%s\n' "$guest_block" | grep -c '^        check_dp$')" -eq 1 ]
[ "$(printf '%s\n' "$guest_v6_block" | grep -c '^        check_dp$')" -eq 1 ]
[ "$(printf '%s\n' "$main_block" | grep -c '^        check_legacy$')" -eq 1 ]
[ "$(printf '%s\n' "$main_v6_block" | grep -c '^        check_legacy$')" -eq 1 ]
echo 'ok - one managed check attaches once to multiple IPv4 and IPv6 instances'

expect_validation_failure missing_target 'dataplane check without targets is rejected'
expect_validation_failure excessive_min 'min_success above target count is rejected'
expect_validation_failure excessive_weight 'keepalived script weight above 253 is rejected'
expect_validation_failure short_timeout 'timeout below the sequential probe worst case is rejected'
expect_validation_failure unknown_instance 'unknown managed VRRP instance is rejected'
expect_validation_failure missing_instance 'dataplane check without a managed instance is rejected'
expect_validation_failure unknown_track 'unknown explicit track_script is rejected'
expect_validation_failure relative_command 'relative custom command is rejected'

echo 'All ha-cluster generator tests passed.'
