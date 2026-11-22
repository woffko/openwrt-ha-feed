#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 woffko
#
# The names of the clients of ISC Kea in dnsmasq's DNS. dnsmasq answers for
# the names of its own DHCP leases and takes no DDNS updates; it reads the
# hosts files of /tmp/hosts at its start and again on SIGHUP. This writes
# one of them, /tmp/hosts/kea-leases, from the lease files of the Kea DHCP
# servers that run on this node: in a Kea HA pair those files hold the
# leases the partner gave out too, so every node can answer for every name.
#
#   kea-dnsmasq-hosts run       the service: rebuilds when Kea's run script
#                               hook said leases changed (at most every
#                               five seconds) and every <interval> seconds
#   kea-dnsmasq-hosts rebuild   once
#   kea-dnsmasq-hosts clear     removes the hosts file
#
# A lease counts when it is active (state 0), has not run out and is an
# address (DHCPv6: IA_NA, /128). Its host name is chosen by the client, so
# only the first label of it is written: a client cannot make the router
# answer for a name of another domain, as dnsmasq would not either, and
# dnsmasq qualifies the label with its own domain (expand-hosts). The label
# must be a host name label (letters, digits, inner hyphens, at most 63),
# and must not be taken: a name of /etc/hosts, of a static lease of
# /etc/config/dhcp, the router's own host name, wpad, isatap, localhost.
# Two clients with one name: the first lease in Kea's files keeps it.
# With no Kea DHCP server running, the file is removed: dnsmasq, back as
# the DHCP server, answers for its own leases.

KDH_RUN_DIR="${KDH_RUN_DIR:-/var/run/kea-dnsmasq-hosts}"
KDH_HOSTS_FILE="${KDH_HOSTS_FILE:-/tmp/hosts/kea-leases}"
KDH_KEA_CONF_DIR="${KDH_KEA_CONF_DIR:-/etc/kea}"
KDH_KEA_LEASE_DIR="${KDH_KEA_LEASE_DIR:-/var/lib/kea}"
KDH_ETC_HOSTS="${KDH_ETC_HOSTS:-/etc/hosts}"
# For tests: KDH_RUNNING, even empty, names the families that count as
# running ("4 6") in place of pgrep; KDH_NOW the time; KDH_HUP the command
# that has dnsmasq read its hosts files again
KDH_RUNNING_SET=""
[ -n "${KDH_RUNNING+set}" ] && KDH_RUNNING_SET=1
KDH_NOW="${KDH_NOW:-}"

log() {
	logger -t kea-dnsmasq-hosts -p "daemon.$1" "$2"
}

# Usage: running <4|6>
running() {
	if [ -n "$KDH_RUNNING_SET" ]; then
		case " $KDH_RUNNING " in *" $1 "*) return 0 ;; esac
		return 1
	fi
	pgrep "kea-dhcp$1" >/dev/null 2>&1
}

# Usage: lease_file <4|6>
# The memfile of the daemon: "lease-database" "name" of its config, else
# Kea's default. A config jsonfilter cannot read (comments) gets the default.
lease_file() {
	local name

	name="$(jsonfilter -i "$KDH_KEA_CONF_DIR/kea-dhcp$1.conf" \
		-e "@.Dhcp$1[\"lease-database\"].name" 2>/dev/null)"
	# An absolute path only: awk would take an operand like a=b for an
	# assignment
	case "$name" in
		/*) ;;
		*) name="$KDH_KEA_LEASE_DIR/kea-leases$1.csv" ;;
	esac
	printf '%s\n' "$name"
}

# Usage: taken_names
# The names a client's DHCP host name must not take, lowercase, one per line
taken_names() {
	awk '$1 !~ /^#/ { for (i = 2; i <= NF; i++) { if ($i ~ /^#/) break; print $i } }' \
		"$KDH_ETC_HOSTS" 2>/dev/null
	uci -q show dhcp 2>/dev/null | sed -n "s/^dhcp\.[^.=]*\.name='\(.*\)'$/\1/p" | tr ' ' '\n'
	uci -q get system.@system[0].hostname 2>/dev/null
	printf '%s\n' wpad isatap localhost
}

# Usage: hosts_of <4|6> <now>
# "address name" for each lease that counts, from the daemon's files: what
# its lease file cleanup (LFC) left (.completed, else .2 then .1), then the
# file itself, in the order Kea reads them at its start. A later line for an
# address replaces an earlier one.
hosts_of() {
	local family="$1" now="$2" memfile taken

	memfile="$(lease_file "$family")"
	set --
	if [ -r "$memfile.completed" ]; then
		set -- "$memfile.completed"
	else
		[ -r "$memfile.2" ] && set -- "$@" "$memfile.2"
		[ -r "$memfile.1" ] && set -- "$@" "$memfile.1"
	fi
	[ -r "$memfile" ] && set -- "$@" "$memfile"
	[ "$#" -gt 0 ] || return 0
	taken="$(taken_names | tr 'A-Z' 'a-z' | sed 's/\..*//' | tr '\n' ' ')"
	awk -F, -v family="$family" -v now="$now" -v taken="$taken" '
		FNR == 1 && $1 == "address" { next }
		{
			if (family == 4) {
				valid = $4; expire = $5; name = $9; state = $10
				type = 0; plen = 128
			} else {
				valid = $3; expire = $4; type = $7; plen = $9
				name = $12; state = $14
			}
			if (state == "") state = 0
			lease[$1] = name
			keep[$1] = (state == 0 && type == 0 && plen == 128 &&
				(valid == 4294967295 || expire + 0 > now + 0))
			if (!($1 in order)) { order[$1] = ++count; addr[count] = $1 }
		}
		END {
			n = split(taken, t, " ")
			for (i = 1; i <= n; i++) used[t[i]] = 1
			for (i = 1; i <= count; i++) {
				a = addr[i]
				if (!keep[a]) continue
				name = lease[a]
				sub(/\..*/, "", name)
				if (length(name) > 63 || name !~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) continue
				lower = tolower(name)
				if (lower in used) continue
				used[lower] = 1
				print a, name
			}
		}' "$@"
}

hup_dnsmasq() {
	if [ -n "$KDH_HUP" ]; then
		eval "$KDH_HUP"
		return 0
	fi
	ubus call service signal '{"name":"dnsmasq","signal":1}' >/dev/null 2>&1 ||
		killall -HUP dnsmasq 2>/dev/null
}

clear_hosts() {
	[ -e "$KDH_HOSTS_FILE" ] || return 0
	rm -f "$KDH_HOSTS_FILE"
	hup_dnsmasq
}

rebuild() {
	local now family tmp any=0

	now="${KDH_NOW:-$(date +%s)}"
	mkdir -p "${KDH_HOSTS_FILE%/*}" 2>/dev/null
	tmp="$(mktemp "$KDH_HOSTS_FILE.XXXXXX")" || return 1
	chmod 0644 "$tmp"
	{
		echo "# Written by kea-dnsmasq-hosts from the leases of Kea - do not edit"
		for family in 4 6; do
			running "$family" || continue
			any=1
			hosts_of "$family" "$now"
		done
	} > "$tmp"
	if [ "$any" -eq 0 ]; then
		rm -f "$tmp"
		clear_hosts
		return 0
	fi
	if cmp -s "$tmp" "$KDH_HOSTS_FILE"; then
		rm -f "$tmp"
		return 0
	fi
	mv -f "$tmp" "$KDH_HOSTS_FILE"
	hup_dnsmasq
}

run() {
	local interval last=0 now

	interval="$(uci -q get kea-dnsmasq-hosts.main.interval)"
	case "$interval" in
		''|*[!0-9]*) interval=60 ;;
	esac
	# Root's, never a link: the hook of Kea writes there
	[ -L "$KDH_RUN_DIR" ] && rm -f "$KDH_RUN_DIR"
	mkdir -m 0755 -p "$KDH_RUN_DIR"
	if [ ! -d "$KDH_RUN_DIR" ] || [ ! -O "$KDH_RUN_DIR" ]; then
		log err "$KDH_RUN_DIR is not a directory of this user: not started"
		exit 1
	fi
	while :; do
		now="$(date +%s)"
		if { [ -e "$KDH_RUN_DIR/changed" ] && [ $((now - last)) -ge 5 ]; } ||
			[ $((now - last)) -ge "$interval" ]; then
			rm -f "$KDH_RUN_DIR/changed"
			rebuild
			last="$now"
		fi
		sleep 2
	done
}

case "$1" in
	run) run ;;
	rebuild) rebuild ;;
	clear) clear_hosts ;;
	*)
		echo "Usage: $0 run|rebuild|clear" >&2
		exit 2
		;;
esac
