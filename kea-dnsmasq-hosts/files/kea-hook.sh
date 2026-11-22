#!/bin/sh
# SPDX-License-Identifier: MIT
# Installed as /usr/share/kea/scripts/kea-dnsmasq-hosts, the one directory
# Kea 3 runs the scripts of its run script hook from. Called by that hook
# (libdhcp_run_script.so, parameter "name") for each lease event of
# kea-dhcp4 and kea-dhcp6. Only notes that leases
# changed: the kea-dnsmasq-hosts service rebuilds dnsmasq's hosts file from
# Kea's lease files, at most every few seconds. Kea runs it asynchronously
# ("sync": false), and its exit code does not matter to Kea.
dir="${KDH_RUN_DIR:-/var/run/kea-dnsmasq-hosts}"
# Made by the service; nothing is written through a link or into a
# directory of another user
[ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || exit 0
: > "$dir/changed" 2>/dev/null
exit 0
