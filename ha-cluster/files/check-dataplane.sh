#!/bin/sh
# SPDX-License-Identifier: MIT
# Package-managed HA dataplane health check for Keepalived vrrp_script.

FUNCTIONS_LIB="${HA_FUNCTIONS_LIB:-/lib/functions.sh}"
SYS_CLASS_NET="${HA_SYS_CLASS_NET:-/sys/class/net}"
IP_BIN="${HA_IP_BIN:-$(command -v ip 2>/dev/null)}"
PING_BIN="${HA_PING_BIN:-$(command -v ping 2>/dev/null)}"
PING6_BIN="${HA_PING6_BIN:-$(command -v ping6 2>/dev/null)}"

[ -r "$FUNCTIONS_LIB" ] || exit 2
. "$FUNCTIONS_LIB"

SECTION="${1:-}"
case "$SECTION" in
	''|*[!A-Za-z0-9_]*) exit 2 ;;
esac

config_load ha-cluster

config_get section_type "$SECTION" TYPE ""
[ "$section_type" = "script" ] || exit 2

config_get check_type "$SECTION" check_type "command"
[ "$check_type" = "dataplane" ] || exit 2

config_get interface "$SECTION" interface ""
config_get bond "$SECTION" bond ""
config_get min_lacp_members "$SECTION" min_lacp_members "0"
config_get min_success "$SECTION" min_success "1"
config_get probe_timeout "$SECTION" probe_timeout "1"

valid_ifname() {
	case "$1" in
		''|*[!A-Za-z0-9_.:-]*) return 1 ;;
	esac
	[ "${#1}" -le 15 ]
}

valid_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

valid_ifname "$interface" || exit 2
valid_uint "$min_lacp_members" || exit 2
valid_uint "$min_success" || exit 2
valid_uint "$probe_timeout" || exit 2
[ "$min_success" -ge 1 ] || exit 2
[ "$probe_timeout" -ge 1 ] || exit 2

[ -d "$SYS_CLASS_NET/$interface" ] || exit 1
[ "$(cat "$SYS_CLASS_NET/$interface/carrier" 2>/dev/null)" = "1" ] || exit 1

if [ -n "$bond" ]; then
	valid_ifname "$bond" || exit 2
	[ -d "$SYS_CLASS_NET/$bond/bonding" ] || exit 1

	if [ "$min_lacp_members" -gt 0 ]; then
		active_ports="$(cat "$SYS_CLASS_NET/$bond/bonding/ad_num_ports" 2>/dev/null)"
		valid_uint "$active_ports" || exit 1
		[ "$active_ports" -ge "$min_lacp_members" ] || exit 1
	fi
fi

[ -n "$IP_BIN" ] && [ -x "$IP_BIN" ] || exit 2
[ -n "$PING_BIN" ] && [ -x "$PING_BIN" ] || exit 2
"$IP_BIN" -o address show >/dev/null 2>&1 || exit 2

is_local_address() {
	local addresses
	addresses="$("$IP_BIN" -o address show to "$1" 2>/dev/null)" || return 2
	[ -n "$addresses" ]
}

eligible_targets=0
successful_targets=0
invalid_targets=0
runtime_error=0

probe_target() {
	local target="$1"
	local local_status ping_command

	# Once the threshold is met, avoid delaying a successful check on optional
	# targets that may be offline.
	[ "$successful_targets" -ge "$min_success" ] && return 0

	case "$target" in
		''|*[!0-9A-Fa-f:.]*) invalid_targets=1; return 0 ;;
	esac
	case "$target" in
		*.*|*:*) ;;
		*) invalid_targets=1; return 0 ;;
	esac

	# The same target list can be installed on both HA nodes. Never let a
	# node satisfy its own health check through one of its local addresses.
	is_local_address "$target"
	local_status=$?
	[ "$local_status" -eq 0 ] && return 0
	[ "$local_status" -eq 2 ] && { runtime_error=1; return 0; }

	eligible_targets=$((eligible_targets + 1))
	ping_command="$PING_BIN"
	case "$target" in
		*:*)
			[ -n "$PING6_BIN" ] && [ -x "$PING6_BIN" ] || { runtime_error=1; return 0; }
			ping_command="$PING6_BIN"
			;;
	esac
	if "$ping_command" -I "$interface" -c 1 -W "$probe_timeout" "$target" >/dev/null 2>&1; then
		successful_targets=$((successful_targets + 1))
	fi
}

config_list_foreach "$SECTION" target probe_target

[ "$invalid_targets" -eq 0 ] || exit 2
[ "$runtime_error" -eq 0 ] || exit 2
[ "$eligible_targets" -ge "$min_success" ] || exit 1
[ "$successful_targets" -ge "$min_success" ] || exit 1
exit 0
