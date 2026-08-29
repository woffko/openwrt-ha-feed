#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
CHECKER="$REPO_ROOT/ha-cluster/files/check-dataplane.sh"
TEST_ROOT="$(mktemp -d)"
SYS_CLASS_NET="$TEST_ROOT/sys/class/net"
PING_LOG="$TEST_ROOT/ping.log"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT/bin" "$SYS_CLASS_NET/bond0.87" "$SYS_CLASS_NET/bond0/bonding"

cat > "$TEST_ROOT/functions.sh" <<'EOF'
config_load() {
	return 0
}

config_get() {
	local destination="$1"
	local option="$3"
	local default="${4:-}"
	local value="$default"

	case "$option" in
		TYPE) value="${TEST_SECTION_TYPE:-script}" ;;
		check_type) value="${TEST_CHECK_TYPE:-dataplane}" ;;
		interface) value="${TEST_INTERFACE:-bond0.87}" ;;
		bond) value="${TEST_BOND:-bond0}" ;;
		min_lacp_members) value="${TEST_MIN_LACP_MEMBERS:-1}" ;;
		min_success) value="${TEST_MIN_SUCCESS:-1}" ;;
		probe_timeout) value="${TEST_PROBE_TIMEOUT:-1}" ;;
	esac
	eval "$destination=\$value"
}

config_list_foreach() {
	local callback="$3"
	local target
	for target in ${TEST_TARGETS:-}; do
		"$callback" "$target"
	done
}
EOF

cat > "$TEST_ROOT/bin/ip" <<'EOF'
#!/bin/sh
[ "${TEST_IP_STATUS:-0}" -eq 0 ] || exit "$TEST_IP_STATUS"

if [ "$1" = "-o" ] && [ "$2" = "address" ] && [ "$3" = "show" ]; then
	if [ "${4:-}" = "to" ]; then
		target="$5"
		case " ${TEST_LOCAL_ADDRESSES:-} " in
			*" $target "*) echo "1: test0 inet $target/24 scope global test0" ;;
		esac
	fi
	exit 0
fi
exit 1
EOF

cat > "$TEST_ROOT/bin/ping" <<'EOF'
#!/bin/sh
target=""
for argument in "$@"; do
	target="$argument"
done
echo "$target" >> "$TEST_PING_LOG"
case " ${TEST_REACHABLE_TARGETS:-} " in
	*" $target "*) exit 0 ;;
esac
exit 1
EOF
chmod +x "$TEST_ROOT/bin/ip" "$TEST_ROOT/bin/ping"

export HA_FUNCTIONS_LIB="$TEST_ROOT/functions.sh"
export HA_SYS_CLASS_NET="$SYS_CLASS_NET"
export HA_IP_BIN="$TEST_ROOT/bin/ip"
export HA_PING_BIN="$TEST_ROOT/bin/ping"
export HA_PING6_BIN="$TEST_ROOT/bin/ping"
export TEST_PING_LOG="$PING_LOG"

reset_case() {
	TEST_SECTION_TYPE='script'
	TEST_CHECK_TYPE='dataplane'
	TEST_INTERFACE='bond0.87'
	TEST_BOND='bond0'
	TEST_MIN_LACP_MEMBERS='1'
	TEST_MIN_SUCCESS='1'
	TEST_PROBE_TIMEOUT='1'
	TEST_TARGETS='192.0.2.10 192.0.2.11'
	TEST_LOCAL_ADDRESSES=''
	TEST_REACHABLE_TARGETS='192.0.2.10'
	TEST_IP_STATUS='0'
	export TEST_SECTION_TYPE TEST_CHECK_TYPE TEST_INTERFACE TEST_BOND
	export TEST_MIN_LACP_MEMBERS TEST_MIN_SUCCESS TEST_PROBE_TIMEOUT
	export TEST_TARGETS TEST_LOCAL_ADDRESSES TEST_REACHABLE_TARGETS TEST_IP_STATUS
	printf '1\n' > "$SYS_CLASS_NET/bond0.87/carrier"
	printf '2\n' > "$SYS_CLASS_NET/bond0/bonding/ad_num_ports"
	: > "$PING_LOG"
}

assert_status() {
	expected="$1"
	label="$2"
	set +e
	sh "$CHECKER" check_wifi
	actual=$?
	set -e
	if [ "$actual" -ne "$expected" ]; then
		echo "not ok - $label (expected $expected, got $actual)" >&2
		exit 1
	fi
	echo "ok - $label"
}

reset_case
assert_status 0 'one reachable target is healthy'

reset_case
TEST_LOCAL_ADDRESSES='192.0.2.10'
TEST_REACHABLE_TARGETS='192.0.2.11'
export TEST_LOCAL_ADDRESSES TEST_REACHABLE_TARGETS
assert_status 0 'local target is skipped and a remote target succeeds'
if grep -qx '192.0.2.10' "$PING_LOG"; then
	echo 'not ok - local target was probed' >&2
	exit 1
fi

reset_case
TEST_TARGETS='192.0.2.10 192.0.2.11 192.0.2.12'
TEST_REACHABLE_TARGETS='192.0.2.10 192.0.2.11 192.0.2.12'
export TEST_TARGETS TEST_REACHABLE_TARGETS
assert_status 0 'probing stops when min_success is reached'
[ "$(wc -l < "$PING_LOG")" -eq 1 ] || {
	echo 'not ok - optional targets were probed after success' >&2
	exit 1
}

reset_case
printf '0\n' > "$SYS_CLASS_NET/bond0.87/carrier"
assert_status 1 'carrier loss is unhealthy'

reset_case
printf '0\n' > "$SYS_CLASS_NET/bond0/bonding/ad_num_ports"
assert_status 1 'insufficient LACP members is unhealthy'

reset_case
TEST_REACHABLE_TARGETS=''
export TEST_REACHABLE_TARGETS
assert_status 1 'all unreachable targets are unhealthy'

reset_case
TEST_MIN_SUCCESS='2'
export TEST_MIN_SUCCESS
assert_status 1 'success count below threshold is unhealthy'

reset_case
TEST_TARGETS='not-a-literal-address'
export TEST_TARGETS
assert_status 2 'invalid target configuration is rejected'

reset_case
TEST_IP_STATUS='1'
export TEST_IP_STATUS
assert_status 2 'local address discovery failure is an execution error'

reset_case
TEST_CHECK_TYPE='command'
export TEST_CHECK_TYPE
assert_status 2 'non-dataplane section is rejected'

reset_case
TEST_TARGETS='2001:db8::10'
TEST_REACHABLE_TARGETS='2001:db8::10'
export TEST_TARGETS TEST_REACHABLE_TARGETS
assert_status 0 'IPv6 targets use the IPv6-capable probe'

echo 'All dataplane checker tests passed.'
