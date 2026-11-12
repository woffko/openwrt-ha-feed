#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
#
# Stock OpenWrt dhcp-script plus one addition for lease-sync: a DHCPv6
# event always carries the client's DUID as DNSMASQ_CLIENT_ID.

[ -f "$USER_DHCPSCRIPT" ] && . "$USER_DHCPSCRIPT" "$@"

. /usr/share/libubox/jshn.sh

# For DHCPv6 dnsmasq passes the full client-id (DUID) as argument 2.
# lease-sync needs it to recreate the lease on the peer. dnsmasq-ha also
# exports it as DNSMASQ_CLIENT_ID (patch 310), but the argument is there
# whatever the environment holds, so it wins.
dhcpv6_client_id=""
case "$1" in
	add | del | old)
		case "$3" in
			*:*) [ -n "$2" ] && [ "$2" != "*" ] && dhcpv6_client_id="$2" ;;
		esac
	;;
esac

json_init
json_add_array env
hotplugobj=""

oldIFS=$IFS
IFS=$'\n'
for var in $(env); do
	# Only NAME=value lines. A client can put a newline in its vendor or
	# user class, and the rest of that value would then be read as a
	# variable of its own, such as DNSMASQ_IAID. dnsmasq cuts these values
	# at their first "=", so such a line never has one.
	case "$var" in
		DNSMASQ_*=*) ;;
		*) continue ;;
	esac
	# Replaced below by the DUID of argument 2
	[ -n "$dhcpv6_client_id" ] && [ "${var%%=*}" = "DNSMASQ_CLIENT_ID" ] && continue
	json_add_string "" "${var%%=*}=${var#*=}"
done
IFS=$oldIFS

[ -n "$dhcpv6_client_id" ] && json_add_string "" "DNSMASQ_CLIENT_ID=$dhcpv6_client_id"

case "$1" in
	add | del | old | arp-add | arp-del)
		json_add_string "" "MACADDR=$2"
		json_add_string "" "IPADDR=$3"
	;;
esac

case "$1" in
	add)
		json_add_string "" "ACTION=add"
		json_add_string "" "HOSTNAME=$4"
		hotplugobj="dhcp"
	;;
	del)
		json_add_string "" "ACTION=remove"
		json_add_string "" "HOSTNAME=$4"
		hotplugobj="dhcp"
	;;
	old)
		json_add_string "" "ACTION=update"
		json_add_string "" "HOSTNAME=$4"
		hotplugobj="dhcp"
	;;
	arp-add)
		json_add_string "" "ACTION=add"
		hotplugobj="neigh"
	;;
	arp-del)
		json_add_string "" "ACTION=remove"
		hotplugobj="neigh"
	;;
	tftp)
		json_add_string "" "ACTION=add"
		json_add_string "" "TFTP_SIZE=$2"
		json_add_string "" "TFTP_ADDR=$3"
		json_add_string "" "TFTP_PATH=$4"
		hotplugobj="tftp"
	;;
esac

json_close_array env

[ -n "$hotplugobj" ] && ubus call hotplug.${hotplugobj} call "$(json_dump)"
