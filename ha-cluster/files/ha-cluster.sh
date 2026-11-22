#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
# Library functions for HA cluster management

HA_CLUSTER_ROOT="${IPKG_INSTROOT:-}"
. "${HA_CLUSTER_ROOT}/lib/functions.sh"
. "${HA_CLUSTER_ROOT}/lib/config/uci.sh"

HA_CLUSTER_CONFIG="/etc/config/ha-cluster"
# Separate from the standalone init scripts' /tmp/*.conf. The directory
# lives under /var/run, which only root can populate, so no other local user
# can pre-create it or plant files before the service starts.
HA_CLUSTER_RUN_DIR="${HA_CLUSTER_RUN_DIR:-/var/run/ha-cluster}"
KEEPALIVED_CONF="${HA_CLUSTER_RUN_DIR}/keepalived.conf"
OWSYNC_CONF="${HA_CLUSTER_RUN_DIR}/owsync.conf"
LEASE_SYNC_CONF="${HA_CLUSTER_RUN_DIR}/lease-sync.conf"
OWSYNC_BIN="${OWSYNC_BIN:-/usr/bin/owsync}"
LEASE_SYNC_BIN="${LEASE_SYNC_BIN:-/usr/sbin/lease-sync}"
KEA_DHCP4_BIN="${KEA_DHCP4_BIN:-/usr/sbin/kea-dhcp4}"
KEA_DHCP6_BIN="${KEA_DHCP6_BIN:-/usr/sbin/kea-dhcp6}"
KEA_CONF_DIR="${KEA_CONF_DIR:-/etc/kea}"
KEA_RUN_DIR="${KEA_RUN_DIR:-/var/run/kea}"
HA_PROC_DIR="${HA_PROC_DIR:-/proc}"
HA_SYS_NET_DIR="${HA_SYS_NET_DIR:-/sys/class/net}"
# The index each device had when netifd last brought its interface up
HA_KEA_DEVICE_DIR="${HA_CLUSTER_RUN_DIR}/kea-devices"
KEA_INIT="${KEA_INIT:-/etc/init.d/kea}"
# luci-app-kea's import of the static leases of dnsmasq into Kea
KEA_IMPORT_BIN="${KEA_IMPORT_BIN:-/usr/libexec/luci-app-kea/import-dnsmasq}"
# The DHCP server this node runs for the cluster interfaces, dnsmasq or kea,
# kept across reboots and upgrades: what a switch starts from
HA_DHCP_BACKEND_STATE="${HA_DHCP_BACKEND_STATE:-${HA_CLUSTER_ROOT}/etc/ha-cluster/dhcp-backend}"
# Why the server asked for is not the one in use, when it is not
HA_DHCP_BACKEND_PROBLEM="${HA_CLUSTER_RUN_DIR}/dhcp-backend-problem"
# What the last import printed
HA_KEA_IMPORT_RESULT="${HA_CLUSTER_RUN_DIR}/kea-import.json"
# Kea was stopped from luci-app-kea while its config says it runs
HA_KEA_STOPPED_MARK="${HA_CLUSTER_RUN_DIR}/kea-stopped"
HA_DHCP_BACKEND_LOCK="${HA_DHCP_BACKEND_LOCK:-/var/lock/ha-cluster-dhcp-backend.lock}"
FW4_BIN="${FW4_BIN:-/sbin/fw4}"
# The changes ha-cluster makes to /etc/config/firewall are staged here, apart
# from what a user has pending in the usual place, and committed on their own
HA_FIREWALL_SAVEDIR="${HA_CLUSTER_RUN_DIR}/uci-firewall"
HA_FIREWALL_LOCK="${HA_FIREWALL_LOCK:-/var/lock/ha-cluster-firewall.lock}"
HA_DATAPLANE_CHECK="${HA_DATAPLANE_CHECK:-/usr/lib/ha-cluster/check-dataplane}"
HA_DHCPV6_GUARD_TABLE="ha_cluster_dhcpv6"
HA_RA_GUARD_TABLE="ha_cluster_ra"
HA_IPV6_GUARD_STATE_DIR="${HA_CLUSTER_RUN_DIR}/ipv6-backup-guard"

HA_LOG_LEVEL_ERROR=0
HA_LOG_LEVEL_WARNING=1
HA_LOG_LEVEL_INFO=2
HA_LOG_LEVEL_DEBUG=3

HA_LOG_LEVEL="${HA_LOG_LEVEL:-2}"

ha_log_init() {
	config_load ha-cluster
	config_get HA_LOG_LEVEL advanced log_level "2"
}

ha_log_error() {
	logger -t ha-cluster -p daemon.err "$@"
}

ha_log_warning() {
	[ "$HA_LOG_LEVEL" -ge "$HA_LOG_LEVEL_WARNING" ] && \
		logger -t ha-cluster -p daemon.warning "$@"
}

ha_log_info() {
	[ "$HA_LOG_LEVEL" -ge "$HA_LOG_LEVEL_INFO" ] && \
		logger -t ha-cluster -p daemon.info "$@"
}

ha_log_debug() {
	[ "$HA_LOG_LEVEL" -ge "$HA_LOG_LEVEL_DEBUG" ] && \
		logger -t ha-cluster -p daemon.debug "$@"
}

ha_log() {
	ha_log_info "$@"
}

# Usage: _ha_list_result=""; config_list_foreach section option _ha_list_collect; myvar="$_ha_list_result"
_ha_list_result=""
_ha_list_collect() {
	_ha_list_result="$_ha_list_result $1"
}

# Append a list item once. Keepalived rejects duplicate track_script entries.
_ha_list_collect_unique() {
	local item
	for item in $_ha_list_result; do
		[ "$item" = "$1" ] && return 0
	done
	_ha_list_result="$_ha_list_result $1"
}

# Collect script sections managed by the current VRRP instance.
_ha_script_instance=""
_ha_collect_managed_script() {
	local script_section="$1"
	local managed_instances managed_instance

	# config_get returns a scalar option unchanged and a UCI list as a
	# space-separated value, so both the legacy single-instance form and the
	# new multi-instance form follow the same path.
	config_get managed_instances "$script_section" vrrp_instance ""
	for managed_instance in $managed_instances; do
		if [ "$managed_instance" = "$_ha_script_instance" ]; then
			_ha_list_collect_unique "$script_section"
			return 0
		fi
	done
	return 0
}

# Usage: ha_conf_append "$file" "key" "$value" ["indent"]
# No-op if value is empty.
ha_conf_append() {
	local file="$1"
	local key="$2"
	local value="$3"
	local indent="${4:-    }"
	[ -n "$value" ] && echo "${indent}${key} ${value}" >> "$file"
}

# Usage: netmask_to_cidr "255.255.255.0" -> "24"
netmask_to_cidr() {
	local netmask="$1"
	local cidr=0

	for octet in $(echo "$netmask" | tr '.' ' '); do
		case "$octet" in
			255) cidr=$((cidr + 8)) ;;
			254) cidr=$((cidr + 7)) ;;
			252) cidr=$((cidr + 6)) ;;
			248) cidr=$((cidr + 5)) ;;
			240) cidr=$((cidr + 4)) ;;
			224) cidr=$((cidr + 3)) ;;
			192) cidr=$((cidr + 2)) ;;
			128) cidr=$((cidr + 1)) ;;
			0) ;;
			*) ha_log_error "Invalid netmask octet '$octet' in '$netmask'"; return 1 ;;
		esac
	done

	echo "$cidr"
}

# Usage: is_valid_ipv6 "fd00::1"
# Coarse syntax check only; LuCI validates on input, keepalived on load.
is_valid_ipv6() {
	local addr="$1"
	case "$addr" in
		*:*) ;;
		*) return 1 ;;
	esac
	# "::" to fully expanded form
	local len=${#addr}
	[ "$len" -lt 2 ] || [ "$len" -gt 39 ] && return 1
	case "$addr" in
		*[!0-9a-fA-F:]*) return 1 ;;
	esac
	return 0
}

ha_get_config() {
	local var="$1"
	local default="$2"
	config_load ha-cluster
	config_get value config "$var" "$default"
	echo "$value"
}

# Sets: _ha_peer_addresses (all peer addresses)
#       _ha_peer_source_address (first non-empty source_address)
_ha_peer_addresses=""
_ha_peer_source_address=""
_ha_collect_peer_address() {
	local section="$1"
	local address source_address

	config_get address "$section" address ""
	config_get source_address "$section" source_address ""

	[ -z "$address" ] && return 0

	_ha_peer_addresses="$_ha_peer_addresses $address"
	if [ -z "$_ha_peer_source_address" ] && [ -n "$source_address" ]; then
		_ha_peer_source_address="$source_address"
	fi
}

# Peers running ha-cluster (not VRRP-only) and having an address
_ha_sync_peer_count=0
_ha_count_sync_peer() {
	local section="$1"
	local address vrrp_only

	config_get_bool vrrp_only "$section" vrrp_only 0
	[ "$vrrp_only" -eq 1 ] && return 0

	config_get address "$section" address ""
	[ -n "$address" ] && _ha_sync_peer_count=$((_ha_sync_peer_count + 1))
}

# Usage: ha_has_sync_peer (ha-cluster config loaded)
ha_has_sync_peer() {
	_ha_sync_peer_count=0
	config_foreach _ha_count_sync_peer peer
	[ "$_ha_sync_peer_count" -gt 0 ]
}

# Usage: ha_resolve_device <destination variable> <logical interface>
# The device of a logical interface. netifd knows it once the interface is
# up; before that, as when the service starts at boot ahead of netifd, the
# device the network config names for the interface is taken. Without it the
# logical name itself went into the keepalived config, and keepalived waited
# for a device of that name for good.
# Fails, with the variable untouched, for a name that is no logical
# interface: the caller then takes the name for a device.
ha_resolve_device() {
	local __ha_dev=""

	. "${HA_CLUSTER_ROOT}/lib/functions/network.sh"
	if network_get_device __ha_dev "$2" 2>/dev/null && [ -n "$__ha_dev" ]; then
		eval "$1=\$__ha_dev"
		return 0
	fi

	[ "$(uci -q get "network.$2")" = "interface" ] || return 1
	__ha_dev="$(uci -q get "network.$2.device")"
	case "$__ha_dev" in
		# Nothing named, several devices, or an alias of another interface
		''|*' '*|@*) return 1 ;;
	esac

	eval "$1=\$__ha_dev"
	return 0
}

# Usage: ha_node_id <address>
# A name for a node that every node of the cluster derives alike: from the
# address the node is reached at by its peers. Kea wants the same server
# names in the config of both servers.
ha_node_id() {
	printf 'ha-%s\n' "$(printf '%s' "$1" | tr '.:' '--')"
}

# Usage: ha_own_address_for <peer address> <source_address of that peer>
# (ha-cluster config loaded)
# This node's own address as that peer reaches it: the source address set
# for the peer, else bind_address, else the one the kernel routes with.
# Never a VIP as long as one of the first two is set.
ha_own_address_for() {
	local peer="$1" source="$2" bind

	if [ -z "$source" ]; then
		config_get bind config bind_address ""
		source="$bind"
	fi
	[ -n "$source" ] ||
		source="$(ip -o route get "$peer" 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -n 1)"

	printf '%s\n' "$source"
}

_ha_include_count=0
_ha_count_include() {
	_ha_include_count=$((_ha_include_count + 1))
}

_ha_count_group_includes() {
	local section="$1"
	local enabled

	config_get_bool enabled "$section" enabled 1
	[ "$enabled" -eq 0 ] && return 0

	config_list_foreach "$section" config_files _ha_count_include
}

# Usage: ha_owsync_wanted (ha-cluster config loaded)
# An enabled sync group lists files and there is a peer to sync with.
ha_owsync_wanted() {
	_ha_include_count=0
	config_foreach _ha_count_group_includes sync_group
	[ "$_ha_include_count" -gt 0 ] && ha_has_sync_peer
}

# Usage: ha_dhcp_backend_mode (ha-cluster config loaded)
# What the config asks for: auto (the default), dnsmasq or kea.
ha_dhcp_backend_mode() {
	local mode

	config_get mode config dhcp_backend "auto"
	printf '%s\n' "$mode"
}

# Usage: ha_dhcp_backend (ha-cluster config loaded)
# Prints the DHCP server this node runs for the cluster interfaces, whose
# leases the cluster keeps in step: dnsmasq, with lease-sync, or kea. Kea
# replicates its leases itself through its high-availability hook, which is
# configured in Kea, not here.
# It is the one the last start switched to (ha_apply_dhcp_backend). A node
# that never switched, as after an upgrade from a release without
# switching, runs Kea if the config says kea, dnsmasq otherwise. Not from
# the pools: /etc/config/dhcp may come from another node, and a switch to
# Kea on a node whose pools are already off for Kea changes nothing there.
ha_dhcp_backend() {
	local backend=""

	[ -r "$HA_DHCP_BACKEND_STATE" ] && read -r backend < "$HA_DHCP_BACKEND_STATE"
	case "$backend" in
		dnsmasq|kea) ;;
		*)
			if [ "$(ha_dhcp_backend_mode)" = "kea" ]; then
				backend="kea"
			else
				backend="dnsmasq"
			fi
			;;
	esac
	printf '%s\n' "$backend"
}

# Usage: ha_dhcp_pools_mismatch (ha-cluster config loaded)
# Prints what the pools of the cluster interfaces say against the server the
# node runs, nothing when they agree: pools switched off for Kea on a node
# that runs dnsmasq (another node switched, /etc/config/dhcp was synced), or
# a pool that gives out DHCPv4 on a node that runs Kea.
ha_dhcp_pools_mismatch() {
	local pools interface pool serving=""

	if ha_dhcp_backend_is_kea; then
		for interface in $(_ha_cluster_dhcp_interfaces); do
			for pool in $(_ha_dhcp_pools_of "$interface"); do
				_ha_dhcp_pool_serves_v4 "$pool" && serving="$serving dhcp.$pool"
			done
		done
		[ -n "$serving" ] &&
			echo "dnsmasq gives out DHCPv4 in$serving while this node runs Kea: two DHCP servers on the cluster interfaces"
	else
		pools="$(_ha_dhcp_pools_switched_off | sed 's/^/dhcp./' | tr '\n' ' ' | sed 's/ $//')"
		[ -n "$pools" ] &&
			echo "dnsmasq's DHCPv4 is switched off for Kea in $pools while this node runs dnsmasq: another node switched to Kea; set the same DHCP server on every node"
	fi
	return 0
}

# Usage: ha_dhcp_backend_is_kea (ha-cluster config loaded)
ha_dhcp_backend_is_kea() {
	[ "$(ha_dhcp_backend)" = "kea" ]
}

# Usage: ha_lease_sync_wanted (ha-cluster config loaded)
# Lease sync is enabled and has a peer to sync with. Never with Kea, whose
# leases lease-sync cannot read or write.
ha_lease_sync_wanted() {
	local lease_sync

	ha_dhcp_backend_is_kea && return 1

	config_get_bool lease_sync config lease_sync 0
	[ "$lease_sync" -eq 1 ] && ha_has_sync_peer
}

# Usage: ha_lease_sync_active (ha-cluster config loaded)
# Gates the lease-sync config, the dhcp force check and the dnsmasq overlay.
ha_lease_sync_active() {
	ha_lease_sync_wanted && [ -x "$LEASE_SYNC_BIN" ]
}

ha_generate_keepalived_conf() {
	local node_name node_priority enable_notifications notification_email_from smtp_server
	local max_auto_priority
	local notification_emails=""

	config_load ha-cluster
	node_name="$(cat /proc/sys/kernel/hostname)"
	config_get node_priority config node_priority "100"
	config_get _ha_vrrp_transport config vrrp_transport "multicast"
	config_get max_auto_priority advanced max_auto_priority "0"
	config_get_bool enable_notifications advanced enable_notifications 0
	config_get notification_email_from advanced notification_email_from ""
	config_get smtp_server advanced smtp_server ""

	_ha_peer_addresses=""
	_ha_peer_source_address=""
	config_foreach _ha_collect_peer_address peer

	_ha_list_result=""
	config_list_foreach advanced notification_email _ha_list_collect
	notification_emails="$_ha_list_result"

	ha_log "Generating keepalived configuration for node: $node_name"

	# Written under another name and renamed once complete: the IPv6 BACKUP
	# guard reads this file whenever keepalived reports a state change
	local conf_final="$KEEPALIVED_CONF"
	KEEPALIVED_CONF="${conf_final}.new"

	# The file carries VRRP authentication passwords: root-only from creation.
	rm -f "$KEEPALIVED_CONF"
	(umask 077; : > "$KEEPALIVED_CONF")
	cat > "$KEEPALIVED_CONF" <<EOF
! Keepalived configuration - Generated by ha-cluster
! DO NOT EDIT - This file is auto-generated when HA cluster is enabled
! Edit /etc/config/ha-cluster instead

global_defs {
    router_id $node_name
    dynamic_interfaces
    script_user root
    enable_script_security
    max_auto_priority $max_auto_priority
EOF

	if [ "$enable_notifications" -eq 1 ]; then
		if [ -n "$notification_emails" ]; then
			cat >> "$KEEPALIVED_CONF" <<EOF
    notification_email {
EOF
			for email in $notification_emails; do
				echo "        $email" >> "$KEEPALIVED_CONF"
			done
			cat >> "$KEEPALIVED_CONF" <<EOF
    }
EOF
		fi
		ha_conf_append "$KEEPALIVED_CONF" "notification_email_from" "$notification_email_from"
		ha_conf_append "$KEEPALIVED_CONF" "smtp_server" "$smtp_server"
	fi

	echo "}" >> "$KEEPALIVED_CONF"
	echo "" >> "$KEEPALIVED_CONF"

	config_foreach ha_generate_vrrp_script script
	config_foreach ha_generate_vrrp_group vrrp_instance

	KEEPALIVED_CONF="$conf_final"
	mv -f "${conf_final}.new" "$conf_final"

	ha_log "Keepalived configuration generated at $KEEPALIVED_CONF"
	return 0
}

ha_generate_vrrp_script() {
	local section="$1"
	local check_type script interval timeout weight rise fall user

	config_get check_type "$section" check_type "command"
	case "$check_type" in
		dataplane) script="$HA_DATAPLANE_CHECK $section" ;;
		command) config_get script "$section" script "" ;;
		*) ha_log_error "script $section: unsupported check_type '$check_type'"; return 1 ;;
	esac
	[ -z "$script" ] && return 0

	config_get interval "$section" interval "5"
	config_get timeout "$section" timeout ""
	config_get weight "$section" weight ""
	config_get rise "$section" rise ""
	config_get fall "$section" fall ""
	config_get user "$section" user ""

	cat >> "$KEEPALIVED_CONF" <<EOF
vrrp_script ${section} {
    script "$script"
    interval $interval
EOF

	ha_conf_append "$KEEPALIVED_CONF" "timeout" "$timeout"
	ha_conf_append "$KEEPALIVED_CONF" "weight" "$weight"
	ha_conf_append "$KEEPALIVED_CONF" "rise" "$rise"
	ha_conf_append "$KEEPALIVED_CONF" "fall" "$fall"
	ha_conf_append "$KEEPALIVED_CONF" "user" "$user"

	echo "}" >> "$KEEPALIVED_CONF"
	echo "" >> "$KEEPALIVED_CONF"
}

# Options shared by the IPv4 and IPv6 instances.
# Uses parent-scope variables: nopreempt, preempt_delay, garp_master_delay,
# track_ifaces, track_scripts, auth_type, auth_pass, unicast_peers, unicast_src_ip
_ha_write_vrrp_instance_options() {
	local label="$1"

	if [ "$nopreempt" -eq 1 ]; then
		echo "    nopreempt" >> "$KEEPALIVED_CONF"
	elif [ -n "$preempt_delay" ]; then
		echo "    preempt_delay $preempt_delay" >> "$KEEPALIVED_CONF"
	fi

	ha_conf_append "$KEEPALIVED_CONF" "garp_master_delay" "$garp_master_delay"

	if [ -n "$track_ifaces" ]; then
		echo "    track_interface {" >> "$KEEPALIVED_CONF"
		for iface in $track_ifaces; do
			local resolved_iface
			if ha_resolve_device resolved_iface "$iface"; then
				ha_log_debug "VIP $label: resolved track_interface '$iface' to device '$resolved_iface'"
				echo "        $resolved_iface" >> "$KEEPALIVED_CONF"
			else
				ha_log_debug "VIP $label: using track_interface '$iface' as-is"
				echo "        $iface" >> "$KEEPALIVED_CONF"
			fi
		done
		echo "    }" >> "$KEEPALIVED_CONF"
	fi

	if [ -n "$track_scripts" ]; then
		echo "    track_script {" >> "$KEEPALIVED_CONF"
		for script_name in $track_scripts; do
			echo "        $script_name" >> "$KEEPALIVED_CONF"
		done
		echo "    }" >> "$KEEPALIVED_CONF"
	fi

	if [ "$auth_type" != "none" ] && [ -n "$auth_pass" ]; then
		cat >> "$KEEPALIVED_CONF" <<EOF
    authentication {
        auth_type $auth_type
        auth_pass "$auth_pass"
    }
EOF
	fi

	if [ -n "$unicast_peers" ]; then
		if [ -n "$unicast_src_ip" ]; then
			ha_conf_append "$KEEPALIVED_CONF" "unicast_src_ip" "$unicast_src_ip"
		fi
		echo "    unicast_peer {" >> "$KEEPALIVED_CONF"
		for peer in $unicast_peers; do
			echo "        $peer" >> "$KEEPALIVED_CONF"
		done
		echo "    }" >> "$KEEPALIVED_CONF"
	fi
}

# Collects the enabled VIPs of $_ha_current_instance.
# Sets: _ha_vip_v4_addrs, _ha_vip_v6_addrs (newline-separated "addr dev iface" entries)
_ha_collect_vip_for_instance() {
	local vip_section="$1"
	local vip_enabled vip_instance vip_interface vip_interface_logical
	local vip_address vip_netmask vip_address6 vip_prefix6

	config_get_bool vip_enabled "$vip_section" enabled 1
	[ "$vip_enabled" -eq 0 ] && return 0

	config_get vip_instance "$vip_section" vrrp_instance ""
	[ "$vip_instance" != "$_ha_current_instance" ] && return 0

	config_get vip_interface_logical "$vip_section" interface ""
	config_get vip_address "$vip_section" address ""
	config_get vip_netmask "$vip_section" netmask "255.255.255.0"
	config_get vip_address6 "$vip_section" address6 ""
	config_get vip_prefix6 "$vip_section" prefix6 "64"

	[ -z "$vip_interface_logical" ] && { ha_log_warning "VIP $vip_section has no interface"; return 1; }
	[ -z "$vip_address" ] && [ -z "$vip_address6" ] && { ha_log_warning "VIP $vip_section has no address (IPv4 or IPv6)"; return 1; }

	# Resolve interface name
	local vip_iface_resolved
	if ha_resolve_device vip_iface_resolved "$vip_interface_logical"; then
		ha_log_debug "VIP $vip_section: resolved interface '$vip_interface_logical' to device '$vip_iface_resolved'"
	else
		vip_iface_resolved="$vip_interface_logical"
		ha_log_debug "VIP $vip_section: using interface '$vip_iface_resolved' as-is"
	fi

	if [ -n "$vip_address" ]; then
		local cidr
		cidr=$(netmask_to_cidr "$vip_netmask") || {
			ha_log_error "VIP $vip_section: invalid netmask '$vip_netmask'"
			return 1
		}
		_ha_vip_v4_addrs="${_ha_vip_v4_addrs}        ${vip_address}/${cidr} dev ${vip_iface_resolved}
"
	fi

	if [ -n "$vip_address6" ]; then
		is_valid_ipv6 "$vip_address6" || { ha_log_error "VIP $vip_section: invalid IPv6 address (got: $vip_address6)"; return 1; }
		case "$vip_prefix6" in
			''|*[!0-9]*) ha_log_error "VIP $vip_section: prefix6 must be a number (got: $vip_prefix6)"; return 1 ;;
		esac
		[ "$vip_prefix6" -lt 1 ] || [ "$vip_prefix6" -gt 128 ] && { ha_log_error "VIP $vip_section: prefix6 must be 1-128 (got: $vip_prefix6)"; return 1; }
		# keepalived wants the first IPv6 address of an instance to be
		# link-local (RFC 5798): those go first, the others keep the order
		# of their sections
		if is_link_local_ipv6 "$vip_address6"; then
			_ha_vip_v6_addrs="        ${vip_address6}/${vip_prefix6} dev ${vip_iface_resolved}
${_ha_vip_v6_addrs}"
		else
			_ha_vip_v6_addrs="${_ha_vip_v6_addrs}        ${vip_address6}/${vip_prefix6} dev ${vip_iface_resolved}
"
		fi
	fi
}

# Usage: is_link_local_ipv6 <address>
# fe80::/10
is_link_local_ipv6() {
	case "$1" in
		[Ff][Ee][89AaBb]?:*) return 0 ;;
	esac
	return 1
}

# Usage: _ha_ip_family "addr" -> "4" or "6"
_ha_ip_family() {
	case "$1" in
		*:*) echo 6 ;;
		*) echo 4 ;;
	esac
}

# Usage: _ha_write_vrrp_instance name vrid vips [evips]
# Uses parent-scope variables of ha_generate_vrrp_group.
_ha_write_vrrp_instance() {
	local name="$1"
	local inst_vrid="$2"
	local vips="$3"
	local evips="$4"

	cat >> "$KEEPALIVED_CONF" <<EOF
vrrp_instance ${name} {
    state BACKUP
    interface $interface
    virtual_router_id $inst_vrid
    priority $priority
    advert_int $advert_int
EOF

	_ha_write_vrrp_instance_options "$name"

	if [ -n "$vips" ]; then
		echo "    virtual_ipaddress {" >> "$KEEPALIVED_CONF"
		printf '%s' "$vips" >> "$KEEPALIVED_CONF"
		echo "    }" >> "$KEEPALIVED_CONF"
	else
		# Only excluded VIPs: fatal for VRRPv3 (IPv6) without it
		echo "    no_virtual_ipaddress" >> "$KEEPALIVED_CONF"
	fi
	if [ -n "$evips" ]; then
		echo "    virtual_ipaddress_excluded {" >> "$KEEPALIVED_CONF"
		printf '%s' "$evips" >> "$KEEPALIVED_CONF"
		echo "    }" >> "$KEEPALIVED_CONF"
	fi

	cat >> "$KEEPALIVED_CONF" <<EOF

    # Notify scripts for state changes
    notify_master "/bin/busybox env -i ACTION=MASTER TYPE=INSTANCE NAME=${name} /sbin/hotplug-call keepalived"
    notify_backup "/bin/busybox env -i ACTION=BACKUP TYPE=INSTANCE NAME=${name} /sbin/hotplug-call keepalived"
    notify_fault "/bin/busybox env -i ACTION=FAULT TYPE=INSTANCE NAME=${name} /sbin/hotplug-call keepalived"
}

EOF
}

# A VRRP instance advertises a single address family. Multicast: one
# keepalived vrrp_instance per UCI vrrp_instance for its IPv4 VIPs, plus a
# second one (VRID+128) for its IPv6 VIPs. Unicast: a single instance in
# the family of its unicast addresses, with the VIPs of the other family
# as excluded (not advertised) addresses.
ha_generate_vrrp_group() {
	local section="$1"
	local interface interface_logical vrid priority nopreempt track_interface
	local advert_int preempt_delay garp_master_delay auth_type auth_pass unicast_src_ip
	local track_ifaces="" track_scripts="" unicast_peers="" unicast_family=""
	local peer first_peer family_peers

	config_get interface_logical "$section" interface
	config_get vrid "$section" vrid
	config_get priority "$section" priority "$(ha_get_config node_priority 100)"
	config_get_bool nopreempt "$section" nopreempt 1
	config_get track_interface "$section" track_interface
	config_get advert_int "$section" advert_int "1"
	config_get preempt_delay "$section" preempt_delay ""
	config_get garp_master_delay "$section" garp_master_delay ""
	config_get auth_type "$section" auth_type "none"
	config_get auth_pass "$section" auth_pass ""
	config_get unicast_src_ip "$section" unicast_src_ip ""

	[ -z "$interface_logical" ] && { ha_log_warning "vrrp_instance $section has no interface"; return 1; }
	[ -z "$vrid" ] && { ha_log_warning "vrrp_instance $section has no VRID"; return 1; }

	# Resolve primary interface
	if ha_resolve_device interface "$interface_logical"; then
		ha_log_debug "vrrp_instance $section: resolved interface '$interface_logical' to device '$interface'"
	else
		interface="$interface_logical"
		ha_log_debug "vrrp_instance $section: using interface '$interface' as-is"
	fi

	# 128-255 are taken by the IPv6 instances (VRID+128)
	case "$vrid" in
		''|*[!0-9]*) ha_log_error "vrrp_instance $section: VRID must be a number (got: $vrid)"; return 1 ;;
	esac
	[ "$vrid" -lt 1 ] || [ "$vrid" -gt 127 ] && { ha_log_error "vrrp_instance $section: VRID must be 1-127 (got: $vrid)"; return 1; }

	case "$priority" in
		''|*[!0-9]*) ha_log_error "vrrp_instance $section: priority must be a number (got: $priority)"; return 1 ;;
	esac
	[ "$priority" -lt 1 ] || [ "$priority" -gt 255 ] && { ha_log_error "vrrp_instance $section: priority must be 1-255 (got: $priority)"; return 1; }

	case "$advert_int" in
		''|*[!0-9]*) ha_log_error "vrrp_instance $section: advert_int must be a number (got: $advert_int)"; return 1 ;;
	esac

	_ha_list_result=""
	config_list_foreach "$section" track_interface _ha_list_collect
	track_ifaces="$_ha_list_result"
	if [ -z "$track_ifaces" ] && [ -n "$track_interface" ]; then
		track_ifaces="$track_interface"
	fi

	# Collect explicit legacy references, then package-managed references from
	# script sections. The latter lets LuCI attach a check without editing the
	# managed VRRP instance itself.
	_ha_list_result=""
	config_list_foreach "$section" track_script _ha_list_collect_unique
	_ha_script_instance="$section"
	config_foreach _ha_collect_managed_script script
	track_scripts="$_ha_list_result"

	case "$auth_type" in
		pass|PASS) auth_type="PASS" ;;
		ah|AH) auth_type="AH" ;;
	esac

	_ha_list_result=""
	config_list_foreach "$section" unicast_peer _ha_list_collect
	unicast_peers="$_ha_list_result"

	# Global unicast transport without a per-instance unicast_peer list:
	# derive peers and source address from the peer sections
	if [ "$_ha_vrrp_transport" = "unicast" ] && [ -z "$unicast_peers" ]; then
		unicast_peers="$_ha_peer_addresses"
		if [ -z "$unicast_src_ip" ] && [ -n "$_ha_peer_source_address" ]; then
			unicast_src_ip="$_ha_peer_source_address"
		fi
		ha_log_debug "vrrp_instance $section: unicast auto-derived from peer config"
	fi

	# keepalived takes the instance family from its first unicast address
	# and skips the addresses of the other family
	if [ -n "$unicast_peers" ]; then
		for first_peer in $unicast_peers; do break; done
		if [ -n "$unicast_src_ip" ]; then
			unicast_family=$(_ha_ip_family "$unicast_src_ip")
			for peer in $unicast_peers; do
				[ "$(_ha_ip_family "$peer")" = "$unicast_family" ] && break
			done
			if [ "$(_ha_ip_family "$peer")" != "$unicast_family" ]; then
				ha_log_error "vrrp_instance $section: no IPv$unicast_family unicast peer for unicast_src_ip $unicast_src_ip, ignoring it"
				unicast_src_ip=""
				unicast_family=$(_ha_ip_family "$first_peer")
			fi
		else
			ha_log_warning "vrrp_instance $section has unicast_peer but no unicast_src_ip"
			unicast_family=$(_ha_ip_family "$first_peer")
		fi
		family_peers=""
		for peer in $unicast_peers; do
			if [ "$(_ha_ip_family "$peer")" = "$unicast_family" ]; then
				family_peers="$family_peers $peer"
			else
				ha_log_warning "vrrp_instance $section: ignoring unicast peer $peer (not IPv$unicast_family)"
			fi
		done
		unicast_peers="$family_peers"
	fi

	_ha_current_instance="$section"
	_ha_vip_v4_addrs=""
	_ha_vip_v6_addrs=""
	config_foreach _ha_collect_vip_for_instance vip

	[ -z "$_ha_vip_v4_addrs" ] && [ -z "$_ha_vip_v6_addrs" ] && {
		ha_log_warning "vrrp_instance $section has no enabled VIPs"
		return 0
	}

	if [ -n "$unicast_peers" ]; then
		if [ "$unicast_family" = 6 ]; then
			_ha_write_vrrp_instance "$section" "$vrid" "$_ha_vip_v6_addrs" "$_ha_vip_v4_addrs"
		else
			_ha_write_vrrp_instance "$section" "$vrid" "$_ha_vip_v4_addrs" "$_ha_vip_v6_addrs"
		fi
		return 0
	fi

	if [ -n "$_ha_vip_v4_addrs" ]; then
		_ha_write_vrrp_instance "$section" "$vrid" "$_ha_vip_v4_addrs"
	fi

	if [ -n "$_ha_vip_v6_addrs" ]; then
		local vrid6=$((vrid + 128))
		if [ "$vrid6" -gt 255 ]; then
			ha_log_error "vrrp_instance $section: IPv6 VRID would be $vrid6 (VRID+128), exceeds 255"
			return 1
		fi

		_ha_write_vrrp_instance "${section}_v6" "$vrid6" "$_ha_vip_v6_addrs"
	fi
}

# Decide the sync security mode from sync_encryption and encryption_key.
# Sets _ha_sync_encrypted to 1 (encrypted) or 0 (operator chose plain mode).
# Returns 1 when encryption is wanted but the key is missing or malformed.
_ha_sync_encrypted=1
ha_sync_encryption_mode() {
	local key="$1" sync_encryption

	config_get_bool sync_encryption config sync_encryption 1
	if [ "$sync_encryption" -eq 0 ]; then
		_ha_sync_encrypted=0
		return 0
	fi
	_ha_sync_encrypted=1
	case "$key" in
		"")
			ha_log_error "sync_encryption is enabled but encryption_key is empty"
			ha_log_error "Set the same key on all nodes, generated in LuCI or with: hexdump -n 32 -v -e '1/1 \"%02x\"' /dev/urandom; or set sync_encryption '0'"
			return 1
			;;
		*[!0-9a-fA-F]*)
			ha_log_error "encryption_key must be 64 hexadecimal characters"
			return 1
			;;
	esac
	[ "${#key}" -eq 64 ] || {
		ha_log_error "encryption_key must be 64 hexadecimal characters (got ${#key})"
		return 1
	}
	return 0
}

ha_generate_owsync_conf() {
	local encryption_key sync_port sync_dir sync_interval owsync_log_level bind_address

	config_load ha-cluster

	if ! ha_owsync_wanted; then
		ha_log_debug "Config sync: no enabled sync group or no peer to sync with"
		rm -f "$OWSYNC_CONF"
		return 0
	fi
	if [ ! -x "$OWSYNC_BIN" ]; then
		ha_log_warning "Config sync enabled but owsync is not installed"
		rm -f "$OWSYNC_CONF"
		return 0
	fi

	config_get encryption_key config encryption_key ""
	config_get sync_port config sync_port "4321"
	config_get sync_dir config sync_dir "/etc/config"
	config_get sync_interval advanced sync_interval "30"
	config_get owsync_log_level advanced owsync_log_level "2"
	config_get bind_address config bind_address ""

	# Plain mode only when the operator switched encryption off explicitly;
	# a missing or malformed key is a configuration error, never a downgrade.
	ha_sync_encryption_mode "$encryption_key" || {
		rm -f "$OWSYNC_CONF"
		return 1
	}

	ha_log "Generating owsync configuration"

	rm -f "$OWSYNC_CONF"
	(umask 077; : > "$OWSYNC_CONF")

	local owsync_bind="${bind_address:-::}"

	cat > "$OWSYNC_CONF" <<EOF
# Auto-generated by ha-cluster
# DO NOT EDIT - changes will be overwritten when HA cluster restarts
# Edit /etc/config/ha-cluster instead

# Network settings
bind_host=${owsync_bind}
port=${sync_port}

# Paths (OpenWrt-specific)
sync_dir=${sync_dir}
database=/etc/owsync/owsync.db

# Daemon settings
poll_interval=${sync_interval}
log_level=${owsync_log_level}

EOF

	# Security settings
	if [ "$_ha_sync_encrypted" -eq 1 ]; then
		echo "# Security: PSK encryption enabled" >> "$OWSYNC_CONF"
		echo "encryption_key=${encryption_key}" >> "$OWSYNC_CONF"
	else
		ha_log_warning "sync_encryption is 0: owsync runs in plain mode (use only over a secure VPN)"
		echo "# Security: Plain mode (use only over secure VPN)" >> "$OWSYNC_CONF"
		echo "plain_mode=1" >> "$OWSYNC_CONF"
	fi
	echo "" >> "$OWSYNC_CONF"

	echo "# Peers" >> "$OWSYNC_CONF"
	config_foreach ha_add_owsync_peer_conf peer
	echo "" >> "$OWSYNC_CONF"

	echo "# Include patterns (sync these files)" >> "$OWSYNC_CONF"
	config_foreach ha_add_owsync_includes_conf sync_group

	echo "" >> "$OWSYNC_CONF"
	echo "# Exclude patterns (never sync these)" >> "$OWSYNC_CONF"
	config_foreach ha_add_owsync_excludes_conf exclude

	ha_log "owsync configuration generated at $OWSYNC_CONF"
	return 0
}

# vrrp_only=1 marks a peer not running ha-cluster
ha_add_owsync_peer_conf() {
	local section="$1"
	local address source_address vrrp_only

	config_get_bool vrrp_only "$section" vrrp_only 0
	[ "$vrrp_only" -eq 1 ] && return 0

	config_get address "$section" address
	config_get source_address "$section" source_address ""

	[ -z "$address" ] && return 0

	if [ -n "$source_address" ]; then
		echo "peer=${address},${source_address}" >> "$OWSYNC_CONF"
		ha_log_debug "owsync peer: $address (source: $source_address)"
	else
		echo "peer=${address}" >> "$OWSYNC_CONF"
		ha_log_debug "owsync peer: $address (no source specified)"
	fi
}

ha_add_owsync_includes_conf() {
	local section="$1"
	local enabled

	config_get_bool enabled "$section" enabled 1
	[ "$enabled" -eq 0 ] && return 0

	config_list_foreach "$section" config_files ha_add_owsync_include_conf
}

ha_add_owsync_include_conf() {
	echo "include=$1" >> "$OWSYNC_CONF"
}

ha_add_owsync_excludes_conf() {
	local section="$1"
	config_list_foreach "$section" file ha_add_owsync_exclude_conf
}

ha_add_owsync_exclude_conf() {
	echo "exclude=$1" >> "$OWSYNC_CONF"
}

ha_generate_lease_sync_conf() {
	local lease_sync_port encryption_key
	local sync_interval peer_timeout log_level node_name bind_address

	config_load ha-cluster

	config_get lease_sync_port advanced lease_sync_port "5378"
	config_get sync_interval advanced lease_sync_interval "30"
	config_get peer_timeout advanced lease_sync_peer_timeout "120"
	config_get log_level advanced lease_sync_log_level "2"
	config_get encryption_key config encryption_key ""
	config_get bind_address config bind_address ""
	node_name="$(cat /proc/sys/kernel/hostname)"

	if ! ha_lease_sync_wanted; then
		ha_log_debug "DHCP lease sync disabled or no peer to sync with"
		rm -f "$LEASE_SYNC_CONF"
		return 0
	fi
	if [ ! -x "$LEASE_SYNC_BIN" ]; then
		ha_log_warning "DHCP lease sync enabled but lease-sync is not installed"
		rm -f "$LEASE_SYNC_CONF"
		return 0
	fi

	ha_sync_encryption_mode "$encryption_key" || {
		rm -f "$LEASE_SYNC_CONF"
		return 1
	}

	ha_log "Generating lease-sync configuration"

	rm -f "$LEASE_SYNC_CONF"
	(umask 077; : > "$LEASE_SYNC_CONF")

	cat > "$LEASE_SYNC_CONF" <<EOF
# Auto-generated by ha-cluster
# DO NOT EDIT - changes will be overwritten when HA cluster restarts
# Edit /etc/config/ha-cluster instead

node_id=${node_name}
sync_port=${lease_sync_port}
sync_interval=${sync_interval}
peer_timeout=${peer_timeout}
log_level=${log_level}
EOF

	# Keeps the VIP from being picked as source address
	if [ -n "$bind_address" ]; then
		echo "bind_address=${bind_address}" >> "$LEASE_SYNC_CONF"
		ha_log "lease-sync will bind to $bind_address"
	fi

	# Security settings: encrypted unless the operator disabled sync_encryption
	if [ "$_ha_sync_encrypted" -eq 1 ]; then
		cat >> "$LEASE_SYNC_CONF" <<EOF

# Security: AES-256-GCM PSK encryption enabled
security_mode=encrypted
psk_key=${encryption_key}
EOF
		ha_log "lease-sync will use AES-256-GCM encryption"
	else
		cat >> "$LEASE_SYNC_CONF" <<EOF

# Security: Plain mode (use only over secure VPN)
# WARNING: Ensure network-layer security (WireGuard/IPsec) is configured!
security_mode=plain
plain_mode_acknowledged=1
EOF
		ha_log_warning "sync_encryption is 0: lease-sync runs in plain mode - ensure network-layer security"
	fi

	echo "" >> "$LEASE_SYNC_CONF"

	config_foreach ha_add_lease_sync_peer_flat peer

	ha_log "lease-sync configuration generated at $LEASE_SYNC_CONF"
	return 0
}

ha_add_lease_sync_peer_flat() {
	local section="$1"
	local address source_address vrrp_only

	config_get_bool vrrp_only "$section" vrrp_only 0
	[ "$vrrp_only" -eq 1 ] && return 0

	config_get address "$section" address
	config_get source_address "$section" source_address ""

	[ -z "$address" ] && return 0

	if [ -n "$source_address" ]; then
		echo "peer=${address},${source_address}" >> "$LEASE_SYNC_CONF"
		ha_log_debug "lease-sync peer: $address (source: $source_address)"
	else
		echo "peer=${address}" >> "$LEASE_SYNC_CONF"
		ha_log_debug "lease-sync peer: $address (no source specified)"
	fi
}

# Validation helpers for package-managed and custom VRRP scripts.
_ha_is_safe_identifier() {
	case "$1" in
		''|*[!A-Za-z0-9_]*) return 1 ;;
	esac
	[ "${#1}" -le 63 ]
}

_ha_is_safe_ifname() {
	case "$1" in
		''|*[!A-Za-z0-9_.:-]*) return 1 ;;
	esac
	[ "${#1}" -le 15 ]
}

_ha_is_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

_ha_is_integer() {
	local value="$1"
	case "$value" in
		-*) value="${value#-}" ;;
	esac
	_ha_is_uint "$value"
}

_ha_validation_error() {
	ha_log_error "$@"
	errors=$((errors + 1))
}

_ha_validate_uint_field() {
	local section="$1"
	local option="$2"
	local value="$3"
	local minimum="$4"
	local maximum="$5"

	[ -z "$value" ] && return 0
	if ! _ha_is_uint "$value" || [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
		_ha_validation_error "script $section: $option must be $minimum-$maximum (got: $value)"
		return 1
	fi
	return 0
}

_ha_target_count=0
_ha_target_invalid=0
_ha_validate_script_target() {
	local target="$1"

	case "$target" in
		''|*[!0-9A-Fa-f:.]*) _ha_target_invalid=1; return 0 ;;
	esac
	case "$target" in
		*.*|*:*) ;;
		*) _ha_target_invalid=1; return 0 ;;
	esac
	_ha_target_count=$((_ha_target_count + 1))
}

ha_check_script_section() {
	local section="$1"
	local check_type script script_exec interval timeout weight rise fall user
	local managed_instances managed_instance managed_type interface bond min_lacp_members min_success probe_timeout

	if ! _ha_is_safe_identifier "$section"; then
		_ha_validation_error "script section has an unsafe name: $section"
		return 1
	fi

	config_get check_type "$section" check_type "command"
	config_get interval "$section" interval "5"
	config_get timeout "$section" timeout ""
	config_get weight "$section" weight ""
	config_get rise "$section" rise ""
	config_get fall "$section" fall ""
	config_get user "$section" user ""
	config_get managed_instances "$section" vrrp_instance ""

	_ha_validate_uint_field "$section" interval "$interval" 1 86400
	_ha_validate_uint_field "$section" timeout "$timeout" 1 86400
	_ha_validate_uint_field "$section" rise "$rise" 1 255
	_ha_validate_uint_field "$section" fall "$fall" 1 255
	if [ -n "$weight" ]; then
		if ! _ha_is_integer "$weight" || [ "$weight" -lt -253 ] || [ "$weight" -gt 253 ]; then
			_ha_validation_error "script $section: weight must be -253..253 (got: $weight)"
		fi
	fi
	if [ -n "$user" ] && ! _ha_is_safe_identifier "$user"; then
		_ha_validation_error "script $section: user contains unsupported characters"
	fi

	for managed_instance in $managed_instances; do
		config_get managed_type "$managed_instance" TYPE ""
		if ! _ha_is_safe_identifier "$managed_instance" || [ "$managed_type" != "vrrp_instance" ]; then
			_ha_validation_error "script $section: vrrp_instance '$managed_instance' does not exist"
		fi
	done

	case "$check_type" in
		command)
			config_get script "$section" script ""
			if [ -z "$script" ]; then
				_ha_validation_error "script $section: Script Command is required"
				return 1
			fi
			case "$script" in
				/*) ;;
				*) _ha_validation_error "script $section: command must use an absolute path"; return 1 ;;
			esac
			if [ "$(printf '%s\n' "$script" | wc -l)" -ne 1 ] || \
				printf '%s' "$script" | LC_ALL=C grep -q '[[:cntrl:]]'; then
				_ha_validation_error "script $section: command cannot contain control characters"
				return 1
			fi
			script_exec="${script%% *}"
			if [ ! -x "${HA_CLUSTER_ROOT}${script_exec}" ]; then
				_ha_validation_error "script $section: executable not found: $script_exec"
			fi
			;;
		dataplane)
			if [ -z "$managed_instances" ]; then
				_ha_validation_error "script $section: at least one vrrp_instance is required for a dataplane check"
			fi
			if [ ! -x "${HA_CLUSTER_ROOT}${HA_DATAPLANE_CHECK}" ]; then
				_ha_validation_error "script $section: dataplane helper is not executable"
			fi

			config_get interface "$section" interface ""
			config_get bond "$section" bond ""
			config_get min_lacp_members "$section" min_lacp_members "0"
			config_get min_success "$section" min_success "1"
			config_get probe_timeout "$section" probe_timeout "1"

			_ha_is_safe_ifname "$interface" || _ha_validation_error "script $section: invalid dataplane interface '$interface'"
			if [ -n "$bond" ] && ! _ha_is_safe_ifname "$bond"; then
				_ha_validation_error "script $section: invalid bond interface '$bond'"
			fi
			_ha_validate_uint_field "$section" min_lacp_members "$min_lacp_members" 0 64
			_ha_validate_uint_field "$section" min_success "$min_success" 1 64
			_ha_validate_uint_field "$section" probe_timeout "$probe_timeout" 1 60
			if _ha_is_uint "$min_lacp_members" && [ "$min_lacp_members" -gt 0 ] && [ -z "$bond" ]; then
				_ha_validation_error "script $section: bond is required when min_lacp_members is greater than 0"
			fi

			_ha_target_count=0
			_ha_target_invalid=0
			config_list_foreach "$section" target _ha_validate_script_target
			if [ "$_ha_target_invalid" -ne 0 ]; then
				_ha_validation_error "script $section: targets must be literal IPv4 or IPv6 addresses"
			fi
			if [ "$_ha_target_count" -eq 0 ]; then
				_ha_validation_error "script $section: at least one target is required"
			elif _ha_is_uint "$min_success" && [ "$min_success" -gt "$_ha_target_count" ]; then
				_ha_validation_error "script $section: min_success exceeds the number of targets"
			fi
			if [ "$_ha_target_count" -gt 0 ] && _ha_is_uint "$probe_timeout" && _ha_is_uint "$interval"; then
				local effective_timeout required_timeout
				effective_timeout="${timeout:-$interval}"
				required_timeout=$((_ha_target_count * probe_timeout + 1))
				if _ha_is_uint "$effective_timeout" && [ "$effective_timeout" -lt "$required_timeout" ]; then
					_ha_validation_error "script $section: timeout must be at least $required_timeout seconds for $_ha_target_count targets"
				fi
			fi
			;;
		*)
			_ha_validation_error "script $section: check_type must be 'command' or 'dataplane'"
			;;
	esac
}

_ha_validate_track_script_ref() {
	local script_name="$1"
	local section_type

	config_get section_type "$script_name" TYPE ""
	if ! _ha_is_safe_identifier "$script_name" || [ "$section_type" != "script" ]; then
		_ha_validation_error "vrrp_instance $_ha_track_instance: unknown track_script '$script_name'"
	fi
}

ha_check_track_script_refs() {
	_ha_track_instance="$1"
	config_list_foreach "$_ha_track_instance" track_script _ha_validate_track_script_ref
}

# Validate ha-cluster configuration
ha_validate_config() {
	local errors=0
	local vrid_list=""

	config_load ha-cluster

	config_get_bool enabled config enabled 0
	[ "$enabled" -eq 0 ] && return 0

	config_foreach ha_check_vrid_unique vrrp_instance

	# Validate script definitions, managed instance references and legacy
	# track_script references before writing keepalived.conf.
	config_foreach ha_check_script_section script
	config_foreach ha_check_track_script_refs vrrp_instance

	# owsync is the only sync backend
	local sync_method
	config_get sync_method config sync_method "owsync"
	[ "$sync_method" != "owsync" ] && {
		ha_log_error "sync_method '$sync_method' is not supported (only 'owsync')"
		errors=$((errors + 1))
	}

	local peer_count=0
	config_foreach ha_count_peers peer
	[ "$peer_count" -eq 0 ] && {
		ha_log_warning "No peers configured - HA will not function"
	}

	# Which DHCP server the cluster works with
	local dhcp_backend
	dhcp_backend="$(ha_dhcp_backend_mode)"
	case "$dhcp_backend" in
		auto|dnsmasq|kea)
			ha_dhcp_backend_is_kea && ha_check_kea_backend
			;;
		*)
			ha_log_error "dhcp_backend '$dhcp_backend' is not supported (only 'auto', 'dnsmasq' and 'kea')"
			errors=$((errors + 1))
			;;
	esac

	# When lease sync is active, VIP interfaces need dhcp.*.force=1
	# so that dnsmasq initializes DHCP (required for ubus add_lease).
	# Without it, the BACKUP node cannot receive synced leases.
	if ha_lease_sync_active; then
		_ha_dhcp_force_checked=""
		config_foreach _ha_check_dhcp_force vip
	fi

	# With sync_encryption enabled (the default) the key must be present and
	# well-formed; otherwise owsync and lease-sync would start without any
	# authentication of their peers. Only checked for a daemon that has
	# work to do.
	local encryption_key
	config_get encryption_key config encryption_key ""
	if ha_owsync_wanted || ha_lease_sync_wanted; then
		ha_sync_encryption_mode "$encryption_key" || errors=$((errors + 1))
	fi

	# Entries of a sync group that owsync never matches
	config_foreach _ha_check_sync_group_entries sync_group

	# Warn only: /etc/config/dhcp belongs to the user
	if ha_dhcp_authoritative_conflict; then
		ha_log_warning "dnsmasq is authoritative while several nodes serve DHCP: they NAK each other's clients"
		ha_log_warning "Set authoritative '0' in /etc/config/dhcp on every node"
	fi

	return $errors
}

# Usage: _ha_check_sync_group_entries <sync_group section>
# owsync syncs files inside /etc/config only: it matches each entry of a
# group against the names of the files there, relative to it, and refuses
# a path that starts with a slash. An entry like /etc/config/apcontroller or
# /root/.ssh therefore syncs nothing, with no word from owsync. Warn only:
# the entry may have been written that way for years, and nothing worse
# happens than before.
_ha_check_sync_group_entries() {
	local section="$1"
	local enabled

	config_get_bool enabled "$section" enabled 1
	[ "$enabled" -eq 1 ] || return 0
	_ha_sync_group_checked="$section"
	config_list_foreach "$section" config_files _ha_check_sync_group_entry
}

_ha_sync_group_checked=""
_ha_check_sync_group_entry() {
	local entry="$1" name

	# A relative entry with a slash may name a file in a directory below
	# /etc/config, which owsync does sync
	case "$entry" in
		/*) ;;
		*) return 0 ;;
	esac

	name="${entry#/etc/config/}"
	if [ "$name" != "$entry" ] && [ -n "$name" ] && [ "${name#*/}" = "$name" ]; then
		ha_log_warning "sync_group $_ha_sync_group_checked: '$entry' syncs nothing, owsync takes names inside /etc/config: write it as '$name'"
	else
		ha_log_warning "sync_group $_ha_sync_group_checked: '$entry' syncs nothing, owsync syncs only files inside /etc/config"
	fi
}

_ha_dnsmasq_authoritative=0
_ha_check_dnsmasq_authoritative() {
	local authoritative

	config_get_bool authoritative "$1" authoritative 0
	[ "$authoritative" -eq 1 ] && _ha_dnsmasq_authoritative=1
}

# Usage: ha_dhcp_authoritative_conflict (ha-cluster config loaded)
# A dnsmasq section is authoritative while several nodes serve DHCP, as
# lease sync or the enabled dhcp sync group listing files implies: an
# authoritative dnsmasq NAKs every request carrying another node's
# server-id.
ha_dhcp_authoritative_conflict() {
	local group_type group_enabled group_files

	# dnsmasq hands out no leases when Kea does
	ha_dhcp_backend_is_kea && return 1

	if ! ha_lease_sync_active; then
		[ -x "$OWSYNC_BIN" ] || return 1
		config_get group_type dhcp TYPE ""
		[ "$group_type" = "sync_group" ] || return 1
		config_get_bool group_enabled dhcp enabled 1
		config_get group_files dhcp config_files ""
		[ "$group_enabled" -eq 1 ] && [ -n "$group_files" ] &&
			ha_has_sync_peer || return 1
	fi

	# In a subshell: config_load keeps the options of the previous config,
	# so /etc/config/dhcp would leak into same-named ha-cluster sections
	(
		_ha_dnsmasq_authoritative=0
		config_load dhcp
		config_foreach _ha_check_dnsmasq_authoritative dnsmasq
		[ "$_ha_dnsmasq_authoritative" -eq 1 ]
	)
}

# Usage: ha_check_kea_backend (ha-cluster config loaded)
# What does not fit Kea as the DHCP server. Warnings only: Kea and
# /etc/config/dhcp belong to the user, and VRRP works whatever they hold.
ha_check_kea_backend() {
	local lease_sync

	[ -x "$KEA_DHCP4_BIN" ] || [ -x "$KEA_DHCP6_BIN" ] ||
		ha_log_warning "Kea is the DHCP server of the cluster but neither kea-dhcp4 nor kea-dhcp6 is installed"

	config_get_bool lease_sync config lease_sync 0
	[ "$lease_sync" -eq 1 ] &&
		ha_log "lease_sync is not used with Kea as the DHCP server: Kea replicates its leases itself"

	_ha_kea_pools_checked=""
	config_foreach _ha_check_kea_dnsmasq_pool vip

	_ha_check_kea_daemon_conf dhcp4
	_ha_check_kea_daemon_conf dhcp6
}

# Usage: ha_kea_daemon_enabled dhcp4|dhcp6
# The Kea init script starts the daemon: its section in /etc/config/kea is
# there and not disabled.
ha_kea_daemon_enabled() {
	local disabled

	[ "$(uci -q get "kea.$1")" = "service" ] || return 1
	disabled="$(uci -q get "kea.$1.disabled")"
	case "$disabled" in
		1|on|true|yes|enabled) return 1 ;;
	esac
	return 0
}

# Usage: ha_kea_conf_names_device dhcp4|dhcp6 <device>
# The daemon listens on the device: its interfaces-config names it, alone or
# with an address after a slash, or names every device ("*"). A config that
# jsonfilter cannot read (one with comments) is searched as text instead,
# skipping the lines that are only a comment, where any mention counts.
ha_kea_conf_names_device() {
	local conf="$KEA_CONF_DIR/kea-$1.conf" key="Dhcp${1#dhcp}" name

	[ -r "$conf" ] || return 1
	if jsonfilter -i "$conf" -e "@.$key" >/dev/null 2>&1; then
		for name in $(jsonfilter -i "$conf" -e "@.$key[\"interfaces-config\"].interfaces[*]" 2>/dev/null); do
			case "$name" in
				"$2"|"$2"/*|"*") return 0 ;;
			esac
		done
		return 1
	fi
	grep -v -e '^[[:space:]]*//' -e '^[[:space:]]*#' "$conf" |
		grep -q -F -e "\"$2\"" -e "\"$2/" -e '"*"'
}

# Usage: _ha_kea_catches_hup <pid>
# The process has a handler for SIGHUP: the lowest bit of the mask of caught
# signals in its status.
_ha_kea_catches_hup() {
	case "$(sed -n 's/^SigCgt:[[:space:]]*//p' "$HA_PROC_DIR/$1/status" 2>/dev/null)" in
		*[13579bdfBDF]) return 0 ;;
	esac
	return 1
}

# Usage: _ha_kea_reload <daemon name> <pid> <logical interface> <device>
# Kea reads its config again on SIGHUP. A Kea in its first moments has no
# handler for the signal yet and would be ended by it, and those moments are,
# at boot, when the interfaces come up: the signal is sent once the process
# catches it, and given up after ten seconds without.
_ha_kea_reload() {
	local name="$1" pid="$2" logical="$3" device="$4"
	local tries=0

	until _ha_kea_catches_hup "$pid"; do
		[ -d "$HA_PROC_DIR/$pid" ] || return 0
		tries=$((tries + 1))
		if [ "$tries" -gt 10 ]; then
			ha_log_warning "Interface '$logical' ($device) is up, but $name (pid $pid) takes no reload signal: restart Kea if it does not answer on $device"
			return 0
		fi
		sleep 1
	done

	kill -HUP "$pid" 2>/dev/null || return 0
	ha_log_info "Interface '$logical' ($device) is up: $name told to read its config again, to listen on the device as it is now"
}

# Usage: ha_kea_device_up <logical interface> <device>
# (ha-cluster config loaded)
# netifd has brought an interface up. Kea opens its DHCP sockets on the
# devices as they are when it reads its config and does not follow them.
# After netifd has made a device anew (ifdown and ifup, a network restart)
# Kea runs, calls its sockets ready, and hears nothing; its partner still
# reaches it and so does not take over, and the clients on that device lose
# their leases. Reading the config again makes Kea open its sockets on the
# device as it is now.
# Only with Kea as the DHCP server of a cluster that is switched on, and only
# for a daemon whose config names the device. The wait for a daemon that has
# just started is left in the background: netifd's other handlers go on.
#
# Reading the config again is not free: it applies whatever the file holds
# by now, and Kea's high availability starts over. So it is asked for only
# when the device is another one than at its last ifup, which its index
# tells: an interface that comes back on the device it had, as after a lost
# carrier, leaves Kea's sockets as they were. The first ifup after boot
# finds no index remembered and counts as a new device: Kea may have started
# before it.
ha_kea_device_up() {
	local logical="$1" device="$2"
	local enabled daemon pid index

	config_get_bool enabled config enabled 0
	[ "$enabled" -eq 1 ] || return 0
	ha_dhcp_backend_is_kea || return 0

	# A name that is no device has no index either
	case "$device" in
		*/*|.|..) return 0 ;;
	esac
	index="$(cat "$HA_SYS_NET_DIR/$device/ifindex" 2>/dev/null || true)"
	[ -n "$index" ] || return 0
	[ "$(cat "$HA_KEA_DEVICE_DIR/$device" 2>/dev/null || true)" = "$index" ] && return 0
	mkdir -m 0700 -p "$HA_CLUSTER_RUN_DIR" "$HA_KEA_DEVICE_DIR" 2>/dev/null || return 0
	printf '%s\n' "$index" > "$HA_KEA_DEVICE_DIR/$device"

	for daemon in dhcp4 dhcp6; do
		ha_kea_conf_names_device "$daemon" "$device" || continue
		for pid in $(pidof "kea-$daemon" 2>/dev/null); do
			_ha_kea_reload "kea-$daemon" "$pid" "$logical" "$device" &
		done
	done
}

# Usage: ha_kea_ha_ports
# The ports of the listeners of Kea's high availability: the port of every
# "url" in the config of each enabled Kea DHCP daemon, one per line, each
# once. Lines that are only a comment are skipped.
ha_kea_ha_ports() {
	local daemon conf

	for daemon in dhcp4 dhcp6; do
		ha_kea_daemon_enabled "$daemon" || continue
		conf="$KEA_CONF_DIR/kea-$daemon.conf"
		[ -r "$conf" ] || continue
		grep -v -e '^[[:space:]]*//' -e '^[[:space:]]*#' "$conf" |
			grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' |
			sed -n 's/.*"https\{0,1\}:\/\/[^"/]*:\([0-9]\{1,5\}\)\(\/[^"]*\)\{0,1\}"$/\1/p'
	done | sort -n -u
}

# A program that prints a Kea daemon's answer to status-get, given the
# control socket as its argument, in place of the ucode below (for tests)
KEA_STATUS_GET="${KEA_STATUS_GET:-}"
# Asks the Kea daemon behind the control socket $KEA_SOCKET for its status.
# Gives up two seconds after the question, so that a Kea that does not answer
# cannot hold up its caller.
KEA_STATUS_UCODE='
import * as socket from "socket";
let s = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);
if (!s || !s.connect({ family: socket.AF_UNIX, path: getenv("KEA_SOCKET") }))
	exit(1);
s.send("{\"command\":\"status-get\"}");
let answer = "";
for (let tries = 0; tries < 20; tries++) {
	if (!length(socket.poll(100, s)))
		continue;
	let chunk = s.recv(16384);
	if (!length(chunk))
		break;
	answer += chunk;
	try { json(answer); break; } catch (e) {}
}
print(answer);
'

# Usage: ha_kea_status_get dhcp4|dhcp6
# Prints Kea's answer to status-get, or nothing: the daemon has no control
# socket under the name the Kea package gives it, the ucode socket module
# (ucode-mod-socket) is not installed, or no answer came.
ha_kea_status_get() {
	local socket="$KEA_RUN_DIR/kea${1#dhcp}-ctrl-socket"

	if [ -n "$KEA_STATUS_GET" ]; then
		"$KEA_STATUS_GET" "$socket" 2>/dev/null
		return 0
	fi

	[ -S "$socket" ] || return 0
	KEA_SOCKET="$socket" ucode -e "$KEA_STATUS_UCODE" 2>/dev/null
}

# The switch between dnsmasq and Kea as the DHCP server of the cluster
# interfaces, the interfaces of the enabled VIPs (option dhcp_backend):
#   auto     Kea when its init script starts kea-dhcp4 and kea-dhcp4's
#            config names the device of a cluster interface, unless Kea was
#            stopped from luci-app-kea since; dnsmasq otherwise. Whether
#            Kea runs is left to Kea's own settings (luci-app-kea).
#   kea      Kea; ha-cluster turns kea-dhcp4 on in /etc/config/kea.
#   dnsmasq  dnsmasq; ha-cluster turns kea-dhcp4 off if it serves a cluster
#            interface.
# DHCPv4 only. On the way to Kea the static leases of dnsmasq are imported
# into Kea first (luci-app-kea), then dnsmasq's DHCPv4 is switched off in the
# pools of the cluster interfaces, then Kea is started; if it does not run
# and listen, the pools are switched on again. On the way back the pools get
# their DHCPv4 back. DNS and the Router Advertisements of dnsmasq stay.
#
# A pool is switched off the visible way: dhcpv4 'disabled', with the value
# it had kept in ha_cluster_dhcpv4 ('unset' when it had none) for the way
# back. /etc/config/dhcp is usually synced between the nodes, so the nodes
# must run the same server: a node changes the pools when it switches
# itself, never because it finds what another node did.

# Usage: _ha_cluster_dhcp_interfaces (ha-cluster config loaded)
# The logical interfaces of the enabled VIPs, one per line, each once
_ha_dhcp_ifaces=""
_ha_collect_dhcp_iface() {
	local enabled interface

	config_get_bool enabled "$1" enabled 1
	[ "$enabled" -eq 1 ] || return 0
	config_get interface "$1" interface ""
	[ -n "$interface" ] || return 0
	case " $_ha_dhcp_ifaces " in
		*" $interface "*) return 0 ;;
	esac
	_ha_dhcp_ifaces="$_ha_dhcp_ifaces $interface"
}
_ha_cluster_dhcp_interfaces() {
	local interface

	_ha_dhcp_ifaces=""
	config_foreach _ha_collect_dhcp_iface vip
	for interface in $_ha_dhcp_ifaces; do
		printf '%s\n' "$interface"
	done
}

# Usage: _ha_dhcp_pools_of <logical interface>
# The dhcp sections (pools) of /etc/config/dhcp for the interface
_ha_dhcp_pools_of() {
	local pool

	for pool in $(uci -q show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dhcp$/\1/p'); do
		[ "$(uci -q get "dhcp.$pool.interface")" = "$1" ] && printf '%s\n' "$pool"
	done
}

# Usage: _ha_dhcp_pool_serves_v4 <pool>
_ha_dhcp_pool_serves_v4() {
	[ "$(uci -q get "dhcp.$1.ignore")" = "1" ] && return 1
	[ "$(uci -q get "dhcp.$1.dhcpv4")" = "disabled" ] && return 1
	return 0
}

# Usage: _ha_dhcp_pool_serves_v6 <pool>
# dnsmasq answers DHCPv6 in a pool when it is the server of its Router
# Advertisements and DHCPv6 is not disabled
_ha_dhcp_pool_serves_v6() {
	[ "$(uci -q get "dhcp.$1.ignore")" = "1" ] && return 1
	[ "$(uci -q get "dhcp.$1.ra")" = "server" ] || return 1
	[ "$(uci -q get "dhcp.$1.dhcpv6")" = "disabled" ] && return 1
	return 0
}

# Usage: _ha_dhcp_pools_switched_off (ha-cluster config loaded)
# The pools of the cluster interfaces whose DHCPv4 was switched off for Kea
_ha_dhcp_pools_switched_off() {
	local interface pool

	for interface in $(_ha_cluster_dhcp_interfaces); do
		for pool in $(_ha_dhcp_pools_of "$interface"); do
			[ -n "$(uci -q get "dhcp.$pool.ha_cluster_dhcpv4")" ] && printf '%s\n' "$pool"
		done
	done
}

# Usage: _ha_dhcp_uci <uci arguments>
# Writes go through a save directory of their own, so that a commit of
# /etc/config/dhcp takes ha-cluster's changes only, not what a user has
# pending in LuCI
HA_DHCP_SAVEDIR="${HA_CLUSTER_RUN_DIR}/uci-dhcp"
_ha_dhcp_uci() {
	mkdir -m 0700 -p "$HA_DHCP_SAVEDIR" 2>/dev/null
	uci -t "$HA_DHCP_SAVEDIR" "$@"
}

# Usage: _ha_dhcp_pools_off
# Switches dnsmasq's DHCPv4 off in the pools of the cluster interfaces that
# still give it out, keeping the value each had, and commits. Prints the
# pools it switched off.
_ha_dhcp_pools_off() {
	local interface pool value changed=""

	for interface in $(_ha_cluster_dhcp_interfaces); do
		for pool in $(_ha_dhcp_pools_of "$interface"); do
			_ha_dhcp_pool_serves_v4 "$pool" || continue
			value="$(uci -q get "dhcp.$pool.dhcpv4")"
			_ha_dhcp_uci -q set "dhcp.$pool.ha_cluster_dhcpv4=${value:-unset}"
			_ha_dhcp_uci -q set "dhcp.$pool.dhcpv4=disabled"
			changed="$changed $pool"
		done
	done
	[ -n "$changed" ] || return 0
	_ha_dhcp_uci commit dhcp
	for pool in $changed; do
		printf '%s\n' "$pool"
	done
}

# Usage: _ha_dhcp_pools_on [<pool>...] (ha-cluster config loaded)
# Gives the pools named, else every pool of the cluster interfaces that was
# switched off for Kea, their DHCPv4 back, and commits. Prints the pools.
_ha_dhcp_pools_on() {
	local pool value changed=""

	[ "$#" -gt 0 ] || set -- $(_ha_dhcp_pools_switched_off)
	for pool in "$@"; do
		value="$(uci -q get "dhcp.$pool.ha_cluster_dhcpv4")"
		[ -n "$value" ] || continue
		if [ "$value" = "unset" ]; then
			_ha_dhcp_uci -q delete "dhcp.$pool.dhcpv4"
		else
			_ha_dhcp_uci -q set "dhcp.$pool.dhcpv4=$value"
		fi
		_ha_dhcp_uci -q delete "dhcp.$pool.ha_cluster_dhcpv4"
		changed="$changed $pool"
	done
	[ -n "$changed" ] || return 0
	_ha_dhcp_uci commit dhcp
	for pool in $changed; do
		printf '%s\n' "$pool"
	done
}

# Usage: _ha_iface_ipv4 <logical interface>
# The first IPv4 address of the interface, from netifd, else from the
# network config; nothing when neither has one
_ha_iface_ipv4() {
	local address

	address="$(ubus call "network.interface.$1" status 2>/dev/null |
		jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)"
	[ -n "$address" ] || address="$(uci -q get "network.$1.ipaddr" | sed 's/[ /].*//')"
	printf '%s\n' "$address"
}

# Usage: _ha_kea4_has_subnet_for <logical interface>
# A subnet4 of kea-dhcp4's config holds the IPv4 address of the interface.
# True as well when that cannot be told: a config that jsonfilter cannot read
# (one with comments), an interface without an address.
_ha_kea4_has_subnet_for() {
	local conf="$KEA_CONF_DIR/kea-dhcp4.conf" address subnets

	address="$(_ha_iface_ipv4 "$1")"
	[ -n "$address" ] || return 0
	jsonfilter -i "$conf" -e '@.Dhcp4' >/dev/null 2>&1 || return 0
	subnets="$(jsonfilter -i "$conf" -e '@.Dhcp4.subnet4[*].subnet' 2>/dev/null || true)
$(jsonfilter -i "$conf" -e '@.Dhcp4["shared-networks"][*].subnet4[*].subnet' 2>/dev/null || true)"
	printf '%s\n' "$subnets" | awk -v ip="$address" '
		function n(a,  p) { split(a, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
		BEGIN { x = n(ip); missing = 1 }
		/^[0-9.]+\/[0-9]+$/ {
			split($0, s, "/")
			size = 2 ^ (32 - s[2])
			if (int(x / size) == int(n(s[1]) / size)) { missing = 0; exit }
		}
		END { exit missing }'
}

# Usage: _ha_kea_set_up_for_cluster (ha-cluster config loaded)
# Kea's init script starts kea-dhcp4 at boot, and kea-dhcp4's config names
# the device of a cluster interface
_ha_kea_set_up_for_cluster() {
	local interface device

	[ -x "$KEA_DHCP4_BIN" ] || return 1
	ha_kea_daemon_enabled dhcp4 || return 1
	[ -x "$KEA_INIT" ] && "$KEA_INIT" enabled 2>/dev/null || return 1
	for interface in $(_ha_cluster_dhcp_interfaces); do
		ha_resolve_device device "$interface" || device="$interface"
		ha_kea_conf_names_device dhcp4 "$device" && return 0
	done
	return 1
}

# Usage: ha_dhcp_backend_wanted (ha-cluster config loaded)
# The DHCP server the cluster interfaces are to have: dnsmasq or kea
ha_dhcp_backend_wanted() {
	case "$(ha_dhcp_backend_mode)" in
		kea) echo "kea" ;;
		dnsmasq) echo "dnsmasq" ;;
		*)
			if _ha_kea_set_up_for_cluster && [ ! -e "$HA_KEA_STOPPED_MARK" ]; then
				echo "kea"
			else
				echo "dnsmasq"
			fi
			;;
	esac
}

# Usage: _ha_kea_usable (ha-cluster config loaded)
# Kea can take DHCPv4 over on every cluster interface where dnsmasq gives
# it out. Leaves why not in _ha_kea_unusable_reason and fails.
_ha_kea_unusable_reason=""
_ha_kea_usable() {
	local conf="$KEA_CONF_DIR/kea-dhcp4.conf" interface pool device

	_ha_kea_unusable_reason=""
	if [ ! -x "$KEA_DHCP4_BIN" ]; then
		_ha_kea_unusable_reason="kea-dhcp4 is not installed"
		return 1
	fi
	if [ ! -r "$conf" ]; then
		_ha_kea_unusable_reason="$conf is missing"
		return 1
	fi
	for interface in $(_ha_cluster_dhcp_interfaces); do
		for pool in $(_ha_dhcp_pools_of "$interface"); do
			if _ha_dhcp_pool_serves_v6 "$pool"; then
				_ha_kea_unusable_reason="dnsmasq gives out DHCPv6 addresses on '$interface' (dhcp.$pool): ha-cluster switches DHCPv4 only, and with Kea lease-sync does not keep those leases in step. Set dhcp.$pool.dhcpv6 to 'disabled', or leave the DHCP server on dnsmasq"
				return 1
			fi
			_ha_dhcp_pool_serves_v4 "$pool" ||
				[ -n "$(uci -q get "dhcp.$pool.ha_cluster_dhcpv4")" ] || continue
			ha_resolve_device device "$interface" || device="$interface"
			if ! ha_kea_conf_names_device dhcp4 "$device"; then
				_ha_kea_unusable_reason="$conf does not name $device, the device of '$interface', in its interfaces"
				return 1
			fi
			if ! _ha_kea4_has_subnet_for "$interface"; then
				_ha_kea_unusable_reason="$conf has no subnet for the address of '$interface'"
				return 1
			fi
		done
	done
	return 0
}

# Usage: _ha_kea_import
# Runs luci-app-kea's import of dnsmasq's static leases (the host sections
# of /etc/config/dhcp) into Kea's DHCP configs: the entries Kea can take as
# they are, not those it would change or take only in part. Keeps what it
# printed in $HA_KEA_IMPORT_RESULT, logs what it left, and sets
# _ha_kea_import_changed to 1 when it wrote Kea's files. Fails when the
# import failed; without luci-app-kea there is no import, with a warning.
_ha_kea_import_changed=0
_ha_kea_import() {
	local out rc=0 result left i key status name identifier address notes

	_ha_kea_import_changed=0
	rm -f "$HA_KEA_IMPORT_RESULT"
	if [ -x "$KEA_IMPORT_BIN" ]; then
		out="$("$KEA_IMPORT_BIN" 2>/dev/null)" || rc=$?
	elif ubus -S list luci.kea >/dev/null 2>&1; then
		out="$(ubus call luci.kea importDnsmasqCommit '{}' 2>/dev/null)" || rc=$?
	else
		ha_log_warning "dnsmasq's static leases are not imported into Kea: luci-app-kea is not installed. A client with a static lease in /etc/config/dhcp keeps its address only if Kea has a reservation for it"
		return 0
	fi
	mkdir -m 0700 -p "$HA_CLUSTER_RUN_DIR" 2>/dev/null
	printf '%s\n' "$out" > "$HA_KEA_IMPORT_RESULT"

	result="$(printf '%s' "$out" | jsonfilter -e '@.result' 2>/dev/null)"
	if [ "$rc" -ne 0 ] || [ "$result" != "true" ]; then
		ha_log_error "The import of dnsmasq's static leases into Kea failed: $(printf '%s' "$out" | jsonfilter -e '@.error' 2>/dev/null || echo "exit code $rc")"
		return 1
	fi
	[ "$(printf '%s' "$out" | jsonfilter -e '@.changed' 2>/dev/null)" = "true" ] && _ha_kea_import_changed=1
	ha_log_info "dnsmasq's static leases imported into Kea: $(printf '%s' "$out" | jsonfilter -e '@.imported' 2>/dev/null || echo 0) new reservations"

	left="$(printf '%s' "$out" | jsonfilter -e '@.left[*].key' 2>/dev/null | wc -l)"
	[ "$left" -gt 0 ] || return 0
	ha_log_warning "$left static leases of dnsmasq are not in Kea: they need luci-app-kea's Import page (Kea > Import from dnsmasq)"
	i=0
	while [ "$i" -lt "$left" ] && [ "$i" -lt 50 ]; do
		eval "$(printf '%s' "$out" | jsonfilter \
			-e "key=@.left[$i].key" -e "status=@.left[$i].status" -e "name=@.left[$i].name" \
			-e "identifier=@.left[$i].identifier" -e "address=@.left[$i].address" 2>/dev/null)"
		notes="$(printf '%s' "$out" | jsonfilter -e "@.left[$i].notes[*]" 2>/dev/null | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
		ha_log_warning "Not imported into Kea ($status): $(echo ${name:-$key} $identifier $address)${notes:+: $notes}"
		key="" status="" name="" identifier="" address=""
		i=$((i + 1))
	done
	return 0
}

# Usage: _ha_kea_wait_dhcp4
# Waits up to $HA_KEA_WAIT seconds (10) for kea-dhcp4 to run with its sockets
# ready, or retrying while an interface is not up yet. A Kea that cannot be
# asked (no ucode socket module) counts once it has run for three seconds.
# Fails when it does not run, or when its sockets are still failed.
HA_KEA_WAIT="${HA_KEA_WAIT:-10}"
_ha_kea_wait_failed=""
_ha_kea_wait_dhcp4() {
	local tries=0 answer status

	_ha_kea_wait_failed="kea-dhcp4 does not run"
	while :; do
		if pgrep kea-dhcp4 >/dev/null 2>&1; then
			answer="$(ha_kea_status_get dhcp4)"
			status="$(printf '%s' "$answer" | jsonfilter -e '@.arguments.sockets.status' 2>/dev/null)"
			case "$status" in
				ready|retrying) return 0 ;;
				'') [ "$tries" -ge 3 ] && return 0 ;;
				*)
					_ha_kea_wait_failed="kea-dhcp4 does not listen: $(printf '%s' "$answer" |
						jsonfilter -e '@.arguments.sockets.errors[0]' 2>/dev/null || echo "sockets $status")"
					;;
			esac
		fi
		[ "$tries" -ge "$HA_KEA_WAIT" ] && return 1
		sleep 1
		tries=$((tries + 1))
	done
}

# Usage: _ha_kea_uci <uci arguments>
HA_KEA_SAVEDIR="${HA_CLUSTER_RUN_DIR}/uci-kea"
_ha_kea_uci() {
	mkdir -m 0700 -p "$HA_KEA_SAVEDIR" 2>/dev/null
	uci -t "$HA_KEA_SAVEDIR" "$@"
}

# Usage: _ha_switch_to_kea <mode> (ha-cluster config loaded)
_ha_switch_to_kea() {
	local mode="$1" pools flag_set=0 init_enabled=0

	if ! _ha_kea_usable; then
		_ha_dhcp_backend_problem "Kea cannot take over: $_ha_kea_unusable_reason"
		return 1
	fi
	if ! _ha_kea_import; then
		_ha_dhcp_backend_problem "the import of dnsmasq's static leases into Kea failed (see the system log): dnsmasq stays the DHCP server"
		return 1
	fi

	# A few seconds without a DHCP server rather than two of them
	pools="$(_ha_dhcp_pools_off)"
	ha_restart_dnsmasq

	if [ "$mode" = "kea" ]; then
		if ! ha_kea_daemon_enabled dhcp4; then
			[ "$(uci -q get kea.dhcp4)" = "service" ] || _ha_kea_uci -q set kea.dhcp4=service
			_ha_kea_uci -q set kea.dhcp4.disabled=0
			_ha_kea_uci commit kea
			flag_set=1
		fi
		if ! "$KEA_INIT" enabled 2>/dev/null; then
			"$KEA_INIT" enable 2>/dev/null
			init_enabled=1
		fi
		"$KEA_INIT" restart >/dev/null 2>&1
	elif ! pgrep kea-dhcp4 >/dev/null 2>&1; then
		"$KEA_INIT" start >/dev/null 2>&1
	elif [ "$_ha_kea_import_changed" -eq 1 ]; then
		"$KEA_INIT" reload >/dev/null 2>&1
	fi

	if ! _ha_kea_wait_dhcp4; then
		[ -n "$pools" ] && _ha_dhcp_pools_on $pools >/dev/null
		if [ "$flag_set" -eq 1 ]; then
			_ha_kea_uci -q set kea.dhcp4.disabled=1
			_ha_kea_uci commit kea
		fi
		[ "$init_enabled" -eq 1 ] && "$KEA_INIT" disable 2>/dev/null
		[ "$mode" = "kea" ] && "$KEA_INIT" restart >/dev/null 2>&1
		ha_restart_dnsmasq
		_ha_dhcp_backend_problem "Kea did not take over ($_ha_kea_wait_failed): dnsmasq is the DHCP server again"
		return 1
	fi

	ha_log_info "Kea is the DHCP server of the cluster interfaces${pools:+: dnsmasq's DHCPv4 switched off in $(echo $pools)}"
	return 0
}

# Usage: _ha_switch_to_dnsmasq <mode> (ha-cluster config loaded)
_ha_switch_to_dnsmasq() {
	local mode="$1" pools interface device

	# Kea off first: a few seconds without a DHCP server rather than two
	if [ "$mode" = "dnsmasq" ] && ha_kea_daemon_enabled dhcp4; then
		for interface in $(_ha_cluster_dhcp_interfaces); do
			ha_resolve_device device "$interface" || device="$interface"
			ha_kea_conf_names_device dhcp4 "$device" || continue
			ha_log_warning "dhcp_backend is 'dnsmasq': kea-dhcp4, which serves '$interface', is switched off in /etc/config/kea"
			_ha_kea_uci -q set kea.dhcp4.disabled=1
			_ha_kea_uci commit kea
			"$KEA_INIT" restart >/dev/null 2>&1
			break
		done
	fi

	pools="$(_ha_dhcp_pools_on)"
	ha_restart_dnsmasq
	ha_log_info "dnsmasq is the DHCP server of the cluster interfaces${pools:+: its DHCPv4 switched on again in $(echo $pools)}"
}

# Usage: _ha_dhcp_backend_problem <text>
_ha_dhcp_backend_problem() {
	ha_log_error "DHCP server of the cluster interfaces: $1"
	mkdir -m 0700 -p "$HA_CLUSTER_RUN_DIR" 2>/dev/null
	printf '%s\n' "$1" > "$HA_DHCP_BACKEND_PROBLEM"
}

# Usage: _ha_dhcp_backend_save dnsmasq|kea
_ha_dhcp_backend_save() {
	local current=""

	[ -r "$HA_DHCP_BACKEND_STATE" ] && read -r current < "$HA_DHCP_BACKEND_STATE"
	[ "$current" = "$1" ] && return 0
	mkdir -p "${HA_DHCP_BACKEND_STATE%/*}" &&
		printf '%s\n' "$1" > "$HA_DHCP_BACKEND_STATE.new" &&
		mv -f "$HA_DHCP_BACKEND_STATE.new" "$HA_DHCP_BACKEND_STATE"
}

# Usage: ha_apply_dhcp_backend (ha-cluster config loaded)
# Brings the DHCP server of the cluster interfaces in line with what is
# asked for (ha_dhcp_backend_wanted), and remembers which one the node runs.
# A switch that cannot be made leaves the server as it was, says why in the
# log and in the status, and is tried again at the next start or reload.
# One switch at a time.
ha_apply_dhcp_backend() {
	local mode current wanted

	mode="$(ha_dhcp_backend_mode)"
	current="$(ha_dhcp_backend)"
	wanted="$(ha_dhcp_backend_wanted)"
	rm -f "$HA_DHCP_BACKEND_PROBLEM"

	if [ "$current" != "$wanted" ]; then
		exec 7>"$HA_DHCP_BACKEND_LOCK"
		flock -w 30 7 2>/dev/null || true
		if [ "$wanted" = "kea" ]; then
			ha_log_info "Switching the DHCP server of the cluster interfaces from dnsmasq to Kea (dhcp_backend '$mode')"
			_ha_switch_to_kea "$mode" && current="kea"
		else
			ha_log_info "Switching the DHCP server of the cluster interfaces from Kea to dnsmasq (dhcp_backend '$mode')"
			_ha_switch_to_dnsmasq "$mode"
			current="dnsmasq"
		fi
		exec 7>&-
	fi

	_ha_dhcp_backend_save "$current"
}

# Usage: ha_kea_changed (ha-cluster config loaded)
# luci-app-kea started, restarted, reloaded or stopped Kea. A Kea that is set
# up for the cluster and does not run now was stopped on purpose: with
# dhcp_backend 'auto' dnsmasq takes the cluster interfaces back until Kea
# runs again, at the latest at the next boot.
ha_kea_changed() {
	mkdir -m 0700 -p "$HA_CLUSTER_RUN_DIR" 2>/dev/null
	if _ha_kea_set_up_for_cluster && ! pgrep kea-dhcp4 >/dev/null 2>&1; then
		: > "$HA_KEA_STOPPED_MARK"
	else
		rm -f "$HA_KEA_STOPPED_MARK"
	fi
}

# The rules ha-cluster keeps in /etc/config/firewall are ordinary rule
# sections named ha_cluster_*, with names that start with HA-Cluster-: they
# show in LuCI and in "uci show firewall" like any rule. They are described
# first as lines of
#   S|section|type      O|section|option|value      L|section|option|value
# (L: one value of a list), from which both the text to compare with what
# the config holds and the commands to write it are made.

# Usage: _ha_fw_sorted <words>
# The words, each once, in an order every node arrives at.
_ha_fw_sorted() {
	local word

	for word in $1; do
		printf '%s\n' "$word"
	done | LC_ALL=C sort -u | tr '\n' ' '
}

_ha_fw_devices=""
_ha_fw_ah_devices=""
# Usage: _ha_fw_instance <vrrp_instance section> (ha-cluster config loaded)
_ha_fw_instance() {
	local section="$1"
	local logical device auth_type

	config_get logical "$section" interface ""
	[ -n "$logical" ] || return 0
	ha_resolve_device device "$logical" || device="$logical"
	case "$device" in
		*[!A-Za-z0-9._@-]*)
			ha_log_warning "vrrp_instance $section: '$device' is no device name; no firewall rule for its VRRP"
			return 0
			;;
	esac
	_ha_fw_devices="$_ha_fw_devices $device"

	config_get auth_type "$section" auth_type "none"
	case "$auth_type" in
		ah|AH) _ha_fw_ah_devices="$_ha_fw_ah_devices $device" ;;
	esac
}

_ha_fw_nodes=""
_ha_fw_sync_nodes=""
_ha_fw_own_unknown=""
# Usage: _ha_fw_peer <peer section> (ha-cluster config loaded)
# Collects the addresses of the nodes: of the peer, and this node's own
# towards it. With both in the rules every node writes the same rules, and
# a firewall config that owsync carries from node to node stays right on
# each of them.
_ha_fw_peer() {
	local section="$1"
	local address source own vrrp_only

	config_get address "$section" address ""
	[ -n "$address" ] || return 0
	case "$address" in
		*[!0-9A-Fa-f:.]*)
			ha_log_warning "peer $section: '$address' is no IP address; no firewall rule for this peer"
			return 0
			;;
	esac
	config_get source "$section" source_address ""
	config_get_bool vrrp_only "$section" vrrp_only 0

	own="$(ha_own_address_for "$address" "$source")"
	case "$own" in
		''|*[!0-9A-Fa-f:.]*)
			_ha_fw_own_unknown="$_ha_fw_own_unknown $address"
			return 0
			;;
	esac

	_ha_fw_nodes="$_ha_fw_nodes $address $own"
	[ "$vrrp_only" -eq 1 ] || _ha_fw_sync_nodes="$_ha_fw_sync_nodes $address $own"
}

# Usage: _ha_fw_rule <section> <name> <protocols> <ports> <source addresses>
# Prints the description of one rule that accepts, from any zone, the
# protocols on the ports from the addresses. Nothing without addresses.
_ha_fw_rule() {
	local section="$1" name="$2" protocols="$3" ports="$4" sources="$5"
	local word

	[ -n "$sources" ] || return 0
	for word in $ports; do
		case "$word" in
			*[!0-9]*) return 0 ;;
		esac
	done

	echo "S|$section|rule"
	echo "O|$section|name|$name"
	echo "O|$section|src|*"
	for word in $protocols; do
		echo "L|$section|proto|$word"
	done
	for word in $sources; do
		echo "L|$section|src_ip|$word"
	done
	for word in $ports; do
		echo "L|$section|dest_port|$word"
	done
	echo "O|$section|target|ACCEPT"
}

# Usage: ha_firewall_rules (ha-cluster config loaded)
# Prints the description of what this node must accept for the cluster to
# work, whatever the zones say:
# - VRRP on the device of each instance, and AH next to it where an instance
#   on that device authenticates with it. The adverts come from the peers'
#   addresses on those devices, which the config does not name, so the
#   device is the limit;
# - from the addresses of the nodes that sync: the port of owsync and the
#   port of lease-sync, each when that daemon has work, and with Kea as the
#   DHCP server the ports of the listeners of its high availability;
# - from the addresses of all nodes: ping, which the status uses.
# What the clients need (DHCP, DNS) is the business of the zones, as it is
# without a cluster.
# Fails, having set _ha_fw_own_unknown, when this node's own address towards
# a peer is not known: rules without it would be wrong on the other node.
ha_firewall_rules() {
	local device port ports nodes sync_nodes section index=0 word

	_ha_fw_devices=""
	_ha_fw_ah_devices=""
	config_foreach _ha_fw_instance vrrp_instance

	_ha_fw_nodes=""
	_ha_fw_sync_nodes=""
	_ha_fw_own_unknown=""
	config_foreach _ha_fw_peer peer
	[ -z "$_ha_fw_own_unknown" ] || return 1
	nodes="$(_ha_fw_sorted "$_ha_fw_nodes")"
	sync_nodes="$(_ha_fw_sorted "$_ha_fw_sync_nodes")"

	for device in $(_ha_fw_sorted "$_ha_fw_devices"); do
		index=$((index + 1))
		section="ha_cluster_vrrp_$index"
		echo "S|$section|rule"
		echo "O|$section|name|HA-Cluster-VRRP-$device"
		echo "O|$section|src|*"
		echo "O|$section|device|$device"
		echo "O|$section|direction|in"
		echo "L|$section|proto|112"
		case " $_ha_fw_ah_devices " in
			*" $device "*) echo "L|$section|proto|51" ;;
		esac
		echo "O|$section|target|ACCEPT"
	done

	if ha_owsync_wanted; then
		config_get port config sync_port "4321"
		_ha_fw_rule ha_cluster_owsync "HA-Cluster-owsync" tcp "$port" "$sync_nodes"
	fi

	if ha_lease_sync_wanted; then
		config_get port advanced lease_sync_port "5378"
		_ha_fw_rule ha_cluster_lease_sync "HA-Cluster-lease-sync" udp "$port" "$sync_nodes"
	fi

	if ha_dhcp_backend_is_kea; then
		ports="$(ha_kea_ha_ports | tr '\n' ' ')"
		[ -n "${ports% }" ] &&
			_ha_fw_rule ha_cluster_kea "HA-Cluster-Kea-HA" tcp "${ports% }" "$sync_nodes"
	fi

	if [ -n "$nodes" ]; then
		section="ha_cluster_ping"
		echo "S|$section|rule"
		echo "O|$section|name|HA-Cluster-ping"
		echo "O|$section|src|*"
		echo "O|$section|proto|icmp"
		echo "L|$section|icmp_type|echo-request"
		for word in $nodes; do
			echo "L|$section|src_ip|$word"
		done
		echo "O|$section|target|ACCEPT"
	fi
	return 0
}

# Usage: _ha_fw_uci <uci arguments>
_ha_fw_uci() {
	uci -t "$HA_FIREWALL_SAVEDIR" "$@"
}

# Usage: _ha_fw_as_shown (the description on stdin)
# The description as "uci show firewall" prints these sections, without the
# leading "firewall.".
_ha_fw_as_shown() {
	awk -F'|' '
		function flush() { if (line != "") { print line; line = "" } }
		$1 == "S" { flush(); print $2 "=" $3 }
		$1 == "O" { flush(); print $2 "." $3 "=\047" $4 "\047" }
		$1 == "L" {
			key = $2 "." $3
			if (line != "" && key == linekey) {
				line = line " \047" $4 "\047"
			} else {
				flush()
				line = key "=\047" $4 "\047"
				linekey = key
			}
		}
		END { flush() }'
}

# Usage: _ha_fw_in_config
# The rules of ha-cluster as the firewall config holds them, in the same
# form.
_ha_fw_in_config() {
	_ha_fw_uci -q show firewall 2>/dev/null | sed -n 's/^firewall\.\(ha_cluster_[A-Za-z0-9_]*[.=].*\)$/\1/p'
}

# Usage: _ha_fw_delete_sections
# Stages the removal of every rule of ha-cluster.
_ha_fw_delete_sections() {
	local section

	for section in $(_ha_fw_in_config | sed -n 's/^\(ha_cluster_[A-Za-z0-9_]*\)=.*/\1/p'); do
		_ha_fw_uci -q delete "firewall.$section"
	done
}

# Usage: _ha_fw_loaded <rule names, one per line>
# The loaded ruleset of firewall4 has every one of these rules. A config
# that owsync brought from another node is not loaded by anybody.
_ha_fw_loaded() {
	local loaded name

	loaded="$(nft list chain inet fw4 input 2>/dev/null)" || return 1
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		case "$loaded" in
			*"\"!fw4: $name\""*) ;;
			*) return 1 ;;
		esac
	done <<EOF
$1
EOF
	return 0
}

# Usage: _ha_fw_reload
# Fails when the firewall is not loaded; then there is nothing to reload.
_ha_fw_reload() {
	[ -x "$FW4_BIN" ] || return 0
	"$FW4_BIN" -q reload >/dev/null 2>&1 ||
		ha_log_debug "firewall4 was not reloaded (it is not loaded)"
	return 0
}

# Usage: _ha_fw_locked <function> [arguments]
# One writer of the firewall config at a time. The start and the reload of
# the service, a stop, and the "firewall" command, which rc.common runs
# outside the lock it takes for start and stop, may meet, and they stage
# their changes in the same directory: two at once would write each list
# twice. The lock is held on a descriptor, so a writer that dies leaves
# none behind. Without a place for the lock file the function runs anyway.
_ha_fw_locked() {
	mkdir -p "${HA_FIREWALL_LOCK%/*}" 2>/dev/null
	if ( : > "$HA_FIREWALL_LOCK" ) 2>/dev/null; then
		{
			flock -x 9 2>/dev/null
			"$@"
		} 9>"$HA_FIREWALL_LOCK"
	else
		"$@"
	fi
}

# Usage: ha_remove_firewall
# Takes the rules of ha-cluster out of the firewall config.
ha_remove_firewall() {
	_ha_fw_locked _ha_remove_firewall
}

_ha_remove_firewall() {
	[ -n "$(_ha_fw_in_config)" ] || return 0

	mkdir -p "$HA_FIREWALL_SAVEDIR" 2>/dev/null || return 0
	_ha_fw_delete_sections
	_ha_fw_uci commit firewall || return 0
	ha_log_info "Firewall rules of the cluster removed from /etc/config/firewall"
	_ha_fw_reload
}

# Usage: ha_apply_firewall (ha-cluster config loaded)
# Makes the firewall config hold the rules the cluster needs, and firewall4
# load them. The config is written only when the rules differ from what it
# holds; firewall4 is reloaded when it was written, or when the rules are
# in the config and not in the loaded ruleset. With option firewall '0' the
# rules are removed and the firewall is the user's alone.
ha_apply_firewall() {
	_ha_fw_locked _ha_apply_firewall
}

_ha_apply_firewall() {
	local wanted description wanted_rules kind section option value names

	# No firewall config: no firewall4 to open anything in
	uci -q show firewall >/dev/null 2>&1 || return 0

	config_get_bool wanted config firewall 1
	if [ "$wanted" -eq 0 ]; then
		_ha_remove_firewall
		return 0
	fi

	# This node's own address is asked of the kernel when the config does not
	# give it, and the kernel does not know it before the interface is up, as
	# at boot. Rules written at an earlier start are right until the config
	# changes, and are left alone.
	description="$(ha_firewall_rules)" || {
		_ha_fw_own_unknown=""
		ha_firewall_rules >/dev/null
		names="$(_ha_fw_in_config | sed -n "s/^[A-Za-z0-9_]*\.name='\(.*\)'$/\1/p")"
		if [ -n "$names" ]; then
			ha_log_info "Firewall rules of the cluster left as they are: this node's own address towards$_ha_fw_own_unknown is not known yet"
			_ha_fw_loaded "$names" || _ha_fw_reload
		else
			ha_log_warning "Firewall rules of the cluster not written: this node's own address towards$_ha_fw_own_unknown is not known. Set bind_address, or source_address of the peer, or reload ha-cluster once the interface is up"
		fi
		return 0
	}
	wanted_rules="$(printf '%s\n' "$description" | _ha_fw_as_shown)"
	names="$(printf '%s\n' "$description" | sed -n 's/^O|[^|]*|name|//p')"

	if [ "$wanted_rules" = "$(_ha_fw_in_config)" ]; then
		[ -z "$names" ] || _ha_fw_loaded "$names" || {
			ha_log_info "Firewall rules of the cluster are in /etc/config/firewall and not loaded: reloading the firewall"
			_ha_fw_reload
		}
		return 0
	fi

	mkdir -p "$HA_FIREWALL_SAVEDIR" 2>/dev/null || return 0
	_ha_fw_delete_sections
	# For tests: time for another writer to step in, were it not held off
	[ -z "${HA_FIREWALL_HOLD:-}" ] || sleep "$HA_FIREWALL_HOLD"
	while IFS='|' read -r kind section option value; do
		case "$kind" in
			S) _ha_fw_uci set "firewall.$section=$option" ;;
			O) _ha_fw_uci set "firewall.$section.$option=$value" ;;
			L) _ha_fw_uci add_list "firewall.$section.$option=$value" ;;
		esac
	done <<EOF
$description
EOF
	_ha_fw_uci commit firewall || {
		ha_log_error "Firewall rules of the cluster could not be written to /etc/config/firewall"
		return 0
	}
	ha_log_info "Firewall rules of the cluster written to /etc/config/firewall (rules named HA-Cluster-...)"

	# A config firewall4 cannot load would keep the whole firewall from
	# loading, now and at boot
	if [ -x "$FW4_BIN" ] && ! "$FW4_BIN" -q check >/dev/null 2>&1; then
		_ha_fw_delete_sections
		_ha_fw_uci commit firewall
		ha_log_error "firewall4 does not pass its check with the rules of ha-cluster: they are taken out again; open what the cluster needs from its peers yourself"
		return 0
	fi
	_ha_fw_reload
}

# Usage: ha_stop_firewall
# As with the IPv6 guard: a node that only stops is still a member, and what
# does not stop with ha-cluster (Kea and its high availability, the peer's
# ping) still needs the rules. They go when the node leaves the cluster.
ha_stop_firewall() {
	local enabled

	config_load ha-cluster
	config_get_bool enabled config enabled 0

	if [ "$enabled" -eq 1 ] && ha_service_enabled; then
		return 0
	fi

	ha_remove_firewall
}

# Usage: _ha_check_kea_daemon_conf dhcp4|dhcp6
# Three things a Kea server of a cluster needs in its config file and that
# only show when they are missed: the high-availability hook, without which
# its leases stay on this node; a port in every "url" of that hook; and
# retries for its sockets, without which a Kea started before the interface
# is up, as at boot, never listens.
# The file is the user's (or luci-app-kea's): warnings only. Lines that are
# only a comment are skipped.
_ha_check_kea_daemon_conf() {
	local daemon="$1"
	local conf="$KEA_CONF_DIR/kea-$daemon.conf"
	local text url

	ha_kea_daemon_enabled "$daemon" || return 0
	[ -r "$conf" ] || {
		ha_log_warning "kea-$daemon is enabled but $conf is missing"
		return 0
	}

	# grep fails when every line is a comment: that is an answer, not an error
	text="$(grep -v -e '^[[:space:]]*//' -e '^[[:space:]]*#' "$conf" || true)"

	printf '%s\n' "$text" | grep -q 'libdhcp_ha' ||
		ha_log_warning "$conf does not load Kea's high-availability hook: unless its lease database is shared, the leases of kea-$daemon stay on this node"

	# Kea takes a url without a port as valid: its listener then gets a port
	# of the kernel's choosing and its partner connects to port 0 (Kea 3.0.4,
	# src/lib/http/url.cc and the listener in ha_service.cc). No such port can
	# be opened in the firewall either.
	url="$(printf '%s\n' "$text" | grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' |
		grep -v ':[0-9]\{1,5\}\(/[^"]*\)\{0,1\}"$' | head -n 1 |
		sed 's/^"url"[[:space:]]*:[[:space:]]*"\(.*\)"$/\1/')"
	[ -z "$url" ] ||
		ha_log_warning "$conf has the url '$url' without a port: Kea does not listen on a port its partner can find, and ha-cluster cannot open one in the firewall. Give every url of Kea's high availability a port"

	printf '%s\n' "$text" | grep -q '"service-sockets-max-retries"[[:space:]]*:[[:space:]]*[1-9]' ||
		ha_log_warning "$conf sets no service-sockets-max-retries: a kea-$daemon started before its interface is up, as at boot, does not listen and does not try again"
}

# A dnsmasq pool on a VIP interface that still answers DHCPv4: two servers
# on one node would answer the same clients
_ha_kea_pools_checked=""
_ha_check_kea_dnsmasq_pool() {
	local section="$1"
	local vip_enabled interface pool pool_interface ignore dhcpv4

	config_get_bool vip_enabled "$section" enabled 1
	[ "$vip_enabled" -eq 0 ] && return 0

	config_get interface "$section" interface ""
	[ -z "$interface" ] && return 0

	echo "$_ha_kea_pools_checked" | grep -qw "$interface" && return 0
	_ha_kea_pools_checked="$_ha_kea_pools_checked $interface"

	# Only type=dhcp sections: dnsmasq sections also have an 'interface' option
	for pool in $(uci show dhcp 2>/dev/null | grep '=dhcp$' | cut -d. -f2 | cut -d= -f1); do
		pool_interface=$(uci -q get "dhcp.$pool.interface")
		[ "$pool_interface" = "$interface" ] || continue

		ignore=$(uci -q get "dhcp.$pool.ignore")
		dhcpv4=$(uci -q get "dhcp.$pool.dhcpv4")
		[ "$ignore" = "1" ] && continue
		[ "$dhcpv4" = "disabled" ] && continue

		ha_log_warning "dnsmasq still answers DHCPv4 on interface '$interface' (dhcp.$pool) while Kea is the DHCP server"
		ha_log_warning "Set dhcp.$pool.dhcpv4='disabled' to keep its router advertisements, or dhcp.$pool.ignore='1'"
	done
}

_ha_dhcp_force_checked=""
_ha_check_dhcp_force() {
	local section="$1"
	local vip_enabled interface

	config_get_bool vip_enabled "$section" enabled 1
	[ "$vip_enabled" -eq 0 ] && return 0

	config_get interface "$section" interface ""
	[ -z "$interface" ] && return 0

	echo "$_ha_dhcp_force_checked" | grep -qw "$interface" && return 0
	_ha_dhcp_force_checked="$_ha_dhcp_force_checked $interface"

	# Only type=dhcp sections: dnsmasq sections also have an 'interface' option
	local dhcp_section force
	dhcp_section=""
	local _s
	for _s in $(uci show dhcp 2>/dev/null | grep '=dhcp$' | cut -d. -f2 | cut -d= -f1); do
		local _iface
		_iface=$(uci -q get "dhcp.$_s.interface")
		if [ "$_iface" = "$interface" ]; then
			dhcp_section="$_s"
			break
		fi
	done
	[ -z "$dhcp_section" ] && return 0

	force=$(uci -q get "dhcp.$dhcp_section.force")
	if [ "$force" != "1" ]; then
		ha_log_error "dhcp.$dhcp_section.force must be '1' for HA lease sync on interface '$interface'"
		ha_log_error "Set it with: uci set dhcp.$dhcp_section.force='1' && uci commit dhcp"
		errors=$((errors + 1))
	fi
}

ha_check_vrid_unique() {
	local section="$1"
	local vrid

	config_get vrid "$section" vrid
	[ -z "$vrid" ] && return 0

	case "$vrid" in
		''|*[!0-9]*) ha_log_error "vrrp_instance $section: VRID must be a number (got: $vrid)"; errors=$((errors + 1)); return 1 ;;
	esac
	[ "$vrid" -gt 127 ] && {
		ha_log_error "vrrp_instance $section: VRID must be 1-127 (got: $vrid, 128-255 reserved for IPv6)"
		errors=$((errors + 1))
		return 1
	}

	# Unique across all instances, even on different interfaces
	echo "$vrid_list" | grep -qw "$vrid" && {
		ha_log_error "Duplicate VRID $vrid in vrrp_instance section $section"
		errors=$((errors + 1))
		return 1
	}

	vrid_list="$vrid_list $vrid"
}

ha_count_peers() {
	peer_count=$((peer_count + 1))
}

# Usage: ha_manage_services take_over|release
# take_over stops and disables the standalone services, recording whether
# each was enabled; release re-enables and starts those that were.
ha_manage_services() {
	local action="$1"
	local state_file="/etc/ha-cluster/service_states"

	mkdir -p /etc/ha-cluster

	if [ "$action" = "take_over" ]; then
		ha_log "Taking over service management from standalone init scripts"

		# State already captured (e.g. on reload): the services are already
		# disabled, so re-capturing would record them as disabled and release
		# could no longer restore their original state.
		[ -f "$state_file" ] && return 0

		for service in keepalived owsync lease-sync; do
			if [ -x "/etc/init.d/$service" ]; then
				if /etc/init.d/$service enabled 2>/dev/null; then
					echo "$service=1" >> "$state_file"
				else
					echo "$service=0" >> "$state_file"
				fi

				/etc/init.d/$service stop 2>/dev/null
				/etc/init.d/$service disable 2>/dev/null
				ha_log "Disabled standalone service: $service"
			fi
		done

	elif [ "$action" = "release" ]; then
		ha_log "Releasing service management back to standalone init scripts"

		[ ! -f "$state_file" ] && return 0

		while IFS='=' read -r service was_enabled; do
			if [ -x "/etc/init.d/$service" ] && [ "$was_enabled" = "1" ]; then
				/etc/init.d/$service enable 2>/dev/null
				/etc/init.d/$service start 2>/dev/null
				ha_log "Restored standalone service: $service"
			fi
		done < "$state_file"

		rm -f "$state_file"
	fi
}

# Dropped into dnsmasq's conf-dir to enable HA-required options at runtime
# without modifying /etc/config/dhcp.
HA_DNSMASQ_OVERLAY_NAME="ha-cluster.conf"

# Same per-section default as dnsmasq's init script; first section wins.
_ha_dnsmasq_confdir=""
_ha_resolve_dnsmasq_confdir_cb() {
	local cfg="$1"
	[ -n "$_ha_dnsmasq_confdir" ] && return 0
	config_get _ha_dnsmasq_confdir "$cfg" confdir "/tmp/dnsmasq${cfg:+.$cfg}.d"
	# Strip a ",*.ext" filter suffix
	_ha_dnsmasq_confdir="${_ha_dnsmasq_confdir%%,*}"
}

ha_get_dnsmasq_confdir() {
	config_load dhcp
	_ha_dnsmasq_confdir=""
	config_foreach _ha_resolve_dnsmasq_confdir_cb dnsmasq
	echo "${_ha_dnsmasq_confdir:-/tmp/dnsmasq.d}"
}

# The one place that restarts dnsmasq, so that a test can replace it
ha_restart_dnsmasq() {
	/etc/init.d/dnsmasq restart 2>/dev/null
}

ha_configure_dnsmasq() {
	local lease_sync_active=0 needs_restart=0
	local confdir overlay_path tmp_overlay

	config_load ha-cluster
	ha_lease_sync_active && lease_sync_active=1

	confdir="$(ha_get_dnsmasq_confdir)"
	overlay_path="$confdir/$HA_DNSMASQ_OVERLAY_NAME"

	if [ "$lease_sync_active" -eq 1 ]; then
		mkdir -p "$confdir"
		# Dot-prefixed so dnsmasq skips it if it (re)starts before the mv
		tmp_overlay="$confdir/.$HA_DNSMASQ_OVERLAY_NAME.new"
		cat > "$tmp_overlay" <<-'EOF'
			# Auto-generated by ha-cluster — do not edit
			# Call dhcp-script on lease renewals so lease-sync can track expiry changes
			script-on-renewal
		EOF
		# Restart only on change: a restart briefly drops DNS/DHCP
		if cmp -s "$tmp_overlay" "$overlay_path"; then
			rm -f "$tmp_overlay"
		else
			mv "$tmp_overlay" "$overlay_path"
			needs_restart=1
			ha_log "Wrote dnsmasq HA overlay to $overlay_path"
		fi
	elif [ -f "$overlay_path" ]; then
		# Left over from a run with lease sync active
		rm -f "$overlay_path"
		needs_restart=1
		ha_log "Removed stale dnsmasq HA overlay"
	fi

	[ "$needs_restart" -eq 1 ] && {
		ha_restart_dnsmasq
		ha_log "dnsmasq restarted"
	}
}

ha_release_dnsmasq() {
	local confdir overlay_path
	confdir="$(ha_get_dnsmasq_confdir)"
	overlay_path="$confdir/$HA_DNSMASQ_OVERLAY_NAME"

	[ ! -f "$overlay_path" ] && return 0

	ha_log "Removing dnsmasq HA overlay"
	rm -f "$overlay_path"
	ha_restart_dnsmasq
}

# Whether the init script starts at boot. A node whose service is disabled
# has been taken out of the cluster.
ha_service_enabled() {
	local link

	for link in "${HA_CLUSTER_ROOT}"/etc/rc.d/S[0-9][0-9]ha-cluster; do
		[ -e "$link" ] && return 0
	done

	return 1
}

# Close the IPv6 BACKUP guard for every keepalived instance, as a STOP of
# each: the handler records BACKUP and blocks the interface of the
# instances that hold IPv6 VIPs. Returns once the rules are in place.
ha_close_ipv6_guard() {
	local handler="${HA_CLUSTER_ROOT}/usr/lib/ha-cluster/ipv6-backup-guard"
	local name i

	[ -r "$handler" ] || handler="${HA_CLUSTER_ROOT}/etc/hotplug.d/keepalived/20-ipv6-backup-guard"
	[ -r "$handler" ] || return 0
	[ -r "$KEEPALIVED_CONF" ] || return 0

	for name in $(sed -n 's/^vrrp_instance \([^ ]*\) {$/\1/p' "$KEEPALIVED_CONF"); do
		ACTION=STOP TYPE=INSTANCE NAME="$name" /bin/sh "$handler" >/dev/null 2>&1
	done

	# A handler that found another one at work left the rules to it
	i=0
	while [ -d "${HA_CLUSTER_RUN_DIR}/ipv6-backup-guard.lock" ] && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i + 1))
	done
}

# The IPv6 BACKUP guard when the service stops. A node that stops but stays
# in the cluster (enabled in the config, started at boot) keeps the guard
# closed for every instance: its dnsmasq, restarted on its own, must not
# advertise the node as a router nor serve DHCPv6. A node taken out of the
# cluster (HA disabled in the config, or the service disabled) gets the
# rules removed.
ha_stop_ipv6_guard() {
	local enabled

	config_load ha-cluster
	config_get_bool enabled config enabled 0

	if [ "$enabled" -eq 1 ] && ha_service_enabled; then
		ha_log "HA cluster stopped but still enabled: IPv6 BACKUP guard stays closed"
		ha_close_ipv6_guard
		return 0
	fi

	ha_release_ipv6_guard
}

# Remove the IPv6 BACKUP guard state and rules of a node that leaves the
# cluster.
ha_release_ipv6_guard() {
	rm -rf "$HA_IPV6_GUARD_STATE_DIR"
	rm -rf "${HA_CLUSTER_RUN_DIR}/ipv6-backup-guard.lock"
	rm -rf "${HA_CLUSTER_RUN_DIR}/dhcpv6-backup-guard" "${HA_CLUSTER_RUN_DIR}/dhcpv6-backup-guard.lock"
	rm -rf "${HA_CLUSTER_RUN_DIR}/ra-backup-guard" "${HA_CLUSTER_RUN_DIR}/ra-backup-guard.lock"
	nft delete table inet "$HA_DHCPV6_GUARD_TABLE" >/dev/null 2>&1 || true
	nft delete table inet "$HA_RA_GUARD_TABLE" >/dev/null 2>&1 || true
}

# Rebuild the IPv6 BACKUP guard from the generated keepalived config and the
# recorded VRRP states. keepalived sends no notify for an instance that a
# reload keeps or removes, so the handler is not called when, for example,
# an IPv6 VIP is added to or removed from a section.
ha_reconcile_ipv6_guard() {
	local handler="${HA_CLUSTER_ROOT}/usr/lib/ha-cluster/ipv6-backup-guard"

	[ -r "$handler" ] || handler="${HA_CLUSTER_ROOT}/etc/hotplug.d/keepalived/20-ipv6-backup-guard"
	[ -r "$handler" ] || return 0

	ACTION=RECONCILE TYPE=INSTANCE NAME= /bin/sh "$handler" >/dev/null 2>&1 &
}

# The migration script of this release, also run at the first boot of an
# image as /etc/uci-defaults/60_ha-cluster-sync-model
HA_MIGRATE_CONFIG="${HA_MIGRATE_CONFIG:-${HA_CLUSTER_ROOT}/usr/lib/ha-cluster/migrate-config}"

# Usage: ha_config_earlier_model
# Prints, one per line, what /etc/config/ha-cluster holds of the model of
# the releases before 2.0 that the migration script changes: nothing for a
# config of this release, which reads none of it: service sections and
# sync_leases leave a node with no file and no lease sync, an anonymous
# advanced section with the defaults instead of its options.
ha_config_earlier_model() {
	local shown sync_method section

	shown="$(uci -q show ha-cluster)" || return 0

	printf '%s\n' "$shown" | grep -q '^ha-cluster\.[^.=]*=service$' &&
		echo "service sections"
	# Only where the migration removes them: elsewhere they would be
	# reported at every start
	for section in $(printf '%s\n' "$shown" | sed -n -E 's/^ha-cluster\.([^.=]*)=(service|sync_group)$/\1/p'); do
		printf '%s\n' "$shown" | grep -qF "ha-cluster.$section.sync_leases=" || continue
		echo "sync_leases"
		break
	done
	for section in $(printf '%s\n' "$shown" | sed -n 's/^ha-cluster\.\([^.=]*\)=peer$/\1/p'); do
		printf '%s\n' "$shown" | grep -qF "ha-cluster.$section.sync_enabled=" || continue
		echo "sync_enabled"
		break
	done
	sync_method="$(uci -q get ha-cluster.config.sync_method)"
	[ -n "$sync_method" ] && [ "$sync_method" != "owsync" ] &&
		echo "sync_method $sync_method"
	# The migration names the first anonymous one, unless one has the name
	if ! printf '%s\n' "$shown" | grep -q '^ha-cluster\.advanced=advanced$' &&
		printf '%s\n' "$shown" | grep -q '^ha-cluster\.@advanced\[[0-9]*\]=advanced$'; then
		echo "an anonymous advanced section"
	fi
	printf '%s\n' "$shown" | grep -q '^ha-cluster\.advanced\.lease_sync_persist_interval=' &&
		echo "lease_sync_persist_interval"
	return 0
}

# Usage: _ha_earlier_model_list
# What ha_config_earlier_model prints, on one line
_ha_earlier_model_list() {
	ha_config_earlier_model | tr '\n' ',' | sed 's/,$//; s/,/, /g'
}

# Usage: ha_guard_handler_stale
# True when /etc/hotplug.d/keepalived holds another IPv6 BACKUP guard
# handler than the one of this release, or one of an earlier release.
# keepalived's state changes run that one; this release's own calls run
# the packaged copy.
ha_guard_handler_stale() {
	local packaged="${HA_CLUSTER_ROOT}/usr/lib/ha-cluster/ipv6-backup-guard"
	local hooks="${HA_CLUSTER_ROOT}/etc/hotplug.d/keepalived"

	[ -f "$packaged" ] || return 1
	cmp -s "$packaged" "$hooks/20-ipv6-backup-guard" || return 0
	[ -e "$hooks/20-dhcpv6-backup-guard" ] || [ -e "$hooks/21-RA-backup-guard" ]
}

# Usage: ha_migrate_earlier_model
# Does at a start what the migration script does at the first boot of an
# image, when its work is not there: when the files it changed were put
# back afterwards. A backup of an earlier release restored in LuCI does
# that; so does sysupgrade when a first-boot script reboots before the boot
# ends (resizing the root partition, for one): /etc/init.d/done deletes the
# settings kept, and preinit unpacks them again at each boot until then,
# after the migration script has run and been deleted.
# Returns 1 when something of the earlier model is still there afterwards.
ha_migrate_earlier_model() {
	local found stale=0 rc=0

	found="$(_ha_earlier_model_list)"
	ha_guard_handler_stale && stale=1
	[ -n "$found" ] || [ "$stale" -eq 1 ] || return 0

	[ -n "$found" ] && ha_log_warning "/etc/config/ha-cluster holds what the releases before 2.0 wrote and this release does not read: $found. It comes back when a backup of an earlier release is restored, or when the first boot of an upgrade reboots before its end. Migrating it now, as the upgrade does"
	[ "$stale" -eq 1 ] && ha_log_warning "/etc/hotplug.d/keepalived holds another IPv6 BACKUP guard handler than the one of this release, which keepalived runs at each state change: putting this release's in place and removing those of earlier releases, as the upgrade does"

	if [ ! -r "$HA_MIGRATE_CONFIG" ]; then
		ha_log_error "The migration script $HA_MIGRATE_CONFIG is missing"
	elif ! /bin/sh "$HA_MIGRATE_CONFIG" >/dev/null 2>&1; then
		ha_log_error "The migration script $HA_MIGRATE_CONFIG failed"
	fi

	if [ -n "$found" ]; then
		found="$(_ha_earlier_model_list)"
		if [ -n "$found" ]; then
			ha_log_error "/etc/config/ha-cluster still holds what this release does not read: $found"
			rc=1
		else
			ha_log_info "/etc/config/ha-cluster migrated to the model of this release"
		fi
	fi
	if [ "$stale" -eq 1 ] && ha_guard_handler_stale; then
		ha_log_error "The IPv6 BACKUP guard handlers in /etc/hotplug.d/keepalived could not be brought in line with this release"
		rc=1
	fi
	return "$rc"
}

ha_apply_config() {
	ha_log "Applying HA cluster configuration"

	ha_validate_config || {
		ha_log_error "Configuration validation failed"
		return 1
	}

	ha_manage_services "take_over"
	ha_configure_dnsmasq

	# Services themselves are started by the init script
	ha_generate_keepalived_conf
	ha_generate_owsync_conf
	ha_generate_lease_sync_conf

	ha_log "HA cluster configuration applied successfully"
	return 0
}
