#!/bin/sh
# SPDX-License-Identifier: MIT
# Called by Kea's run script hook (libdhcp_run_script.so, parameter "name")
# for each lease event of kea-dhcp4 and kea-dhcp6. Only notes that leases
# changed: the kea-dnsmasq-hosts service rebuilds dnsmasq's hosts file from
# Kea's lease files, at most every few seconds. Kea runs it asynchronously
# ("sync": false), and its exit code does not matter to Kea.
dir="${KDH_RUN_DIR:-/var/run/kea-dnsmasq-hosts}"
mkdir -p "$dir" 2>/dev/null
: > "$dir/changed" 2>/dev/null
exit 0
