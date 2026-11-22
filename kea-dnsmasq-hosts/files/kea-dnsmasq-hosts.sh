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
# A lease counts when it is active (state 0), has not run out, is an
# address (DHCPv6: IA_NA, /128), and has a host name made of letters,
# digits, hyphens and dots. A name with dots is written as it is and with
# its first label, which dnsmasq qualifies with its domain (expand-hosts).
# With no Kea DHCP server running, the file is removed: dnsmasq, back as
# the DHCP server, answers for its own leases.

KDH_RUN_DIR="${KDH_RUN_DIR:-/var/run/kea-dnsmasq-hosts}"
KDH_HOSTS_FILE="${KDH_HOSTS_FILE:-/tmp/hosts/kea-leases}"
KDH_KEA_CONF_DIR="${KDH_KEA_CONF_DIR:-/etc/kea}"
KDH_KEA_LEASE_DIR="${KDH_KEA_LEASE_DIR:-/var/lib/kea}"
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
	[ -n "$name" ] || name="$KDH_KEA_LEASE_DIR/kea-leases$1.csv"
	printf '%s\n' "$name"
}

# Usage: lease_files <memfile>
# The files Kea reads at its start, in its order: what its lease file
# cleanup (LFC) left (.completed, else .2 then .1), then the file itself.
# A later line for an address replaces an earlier one.
lease_files() {
	if [ -r "$1.completed" ]; then
		echo "$1.completed"
	else
		[ -r "$1.2" ] && echo "$1.2"
		[ -r "$1.1" ] && echo "$1.1"
	fi
	[ -r "$1" ] && echo "$1"
}

# Usage: hosts_of <4|6> <now>
# "address name..." for each lease that counts, from the daemon's files
hosts_of() {
	local family="$1" now="$2" files

	files="$(lease_files "$(lease_file "$family")")"
	[ -n "$files" ] || return 0
	# shellcheck disable=SC2086
	awk -F, -v family="$family" -v now="$now" '
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
			for (i = 1; i <= count; i++) {
				a = addr[i]
				if (!keep[a]) continue
				name = lease[a]
				sub(/\.$/, "", name)
				if (name !~ /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/) continue
				if (name ~ /\./) {
					short = name
					sub(/\..*/, "", short)
					print a, name, short
				} else {
					print a, name
				}
			}
		}' $files
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
	tmp="$KDH_HOSTS_FILE.new.$$"
	mkdir -p "${KDH_HOSTS_FILE%/*}" 2>/dev/null
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
	mkdir -p "$KDH_RUN_DIR"
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
