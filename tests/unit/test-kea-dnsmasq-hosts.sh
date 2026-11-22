#!/bin/sh
# SPDX-License-Identifier: MIT
#
# kea-dnsmasq-hosts: the hosts file it writes for dnsmasq from Kea's lease
# files. Runs "rebuild" against a temporary root, lease files in Kea's CSV
# format and a fixed time, without a router: which leases count, the names
# it writes, the files of Kea's lease file cleanup, the daemons that run,
# and when dnsmasq is told to read the file again. jsonfilter is not needed:
# without it the lease files are Kea's defaults.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
KDH="$REPO_ROOT/kea-dnsmasq-hosts/files/kea-dnsmasq-hosts.sh"
HOOK="$REPO_ROOT/kea-dnsmasq-hosts/files/kea-hook.sh"
TEST_ROOT="$(mktemp -d)"
FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

export KDH_HOSTS_FILE="$TEST_ROOT/hosts/kea-leases"
export KDH_KEA_CONF_DIR="$TEST_ROOT/etc-kea"
export KDH_KEA_LEASE_DIR="$TEST_ROOT/lib-kea"
export KDH_RUN_DIR="$TEST_ROOT/run"
export KDH_NOW=1800000000
export KDH_HUP="echo hup >> '$TEST_ROOT/hup.log'"
mkdir -p "$KDH_KEA_LEASE_DIR" "$KDH_KEA_CONF_DIR"

V4="$KDH_KEA_LEASE_DIR/kea-leases4.csv"
V6="$KDH_KEA_LEASE_DIR/kea-leases6.csv"
H4="address,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,fqdn_rev,hostname,state,user_context,pool_id"
H6="address,duid,valid_lifetime,expire,subnet_id,pref_lifetime,lease_type,iaid,prefix_len,fqdn_fwd,fqdn_rev,hostname,hwaddr,state,user_context,hwtype,hwaddr_source,pool_id"
LATER=1800003600
EARLIER=1799996400

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; FAILED=1; }

# Usage: rebuild <families running>
rebuild() {
	KDH_RUNNING="$1" sh "$KDH" rebuild
}

# Usage: expect_hosts <description> <expected lines, after the header>
expect_hosts() {
	local got
	got="$(tail -n +2 "$KDH_HOSTS_FILE" 2>/dev/null || true)"
	if [ "$got" = "$2" ]; then
		pass "$1"
	else
		fail "$1"
		printf '    expected: %s\n    got:      %s\n' "$(echo "$2" | tr '\n' '|')" "$(echo "$got" | tr '\n' '|')"
	fi
}

hups() {
	cat "$TEST_ROOT/hup.log" 2>/dev/null | wc -l | tr -d ' '
}

cat > "$V4" <<EOF
$H4
192.168.50.101,02:00:00:00:00:01,,43200,$LATER,1,0,0,laptop,0,,0
192.168.50.102,02:00:00:00:00:02,,43200,$EARLIER,1,0,0,gone,0,,0
192.168.50.103,02:00:00:00:00:03,,43200,$LATER,1,0,0,declined,1,,0
192.168.50.104,02:00:00:00:00:04,,43200,$LATER,1,0,0,reclaimed,2,,0
192.168.50.105,02:00:00:00:00:05,,43200,$LATER,1,0,0,,0,,0
192.168.50.106,02:00:00:00:00:06,,43200,$LATER,1,1,1,phone.lan.,0,,0
192.168.50.107,02:00:00:00:00:07,,43200,$LATER,1,0,0,bad_name,0,,0
192.168.50.108,02:00:00:00:00:08,,43200,$LATER,1,0,0,-dash,0,,0
192.168.50.109,02:00:00:00:00:09,,4294967295,0,1,0,0,forever,0,,0
192.168.50.110,02:00:00:00:00:10,,43200,$LATER,1,0,0,tv,0,,0
192.168.50.110,02:00:00:00:00:10,,0,$LATER,1,0,0,tv,3,,0
192.168.50.111,02:00:00:00:00:11,,43200,$EARLIER,1,0,0,renewed,0,,0
192.168.50.111,02:00:00:00:00:11,,43200,$LATER,1,0,0,renewed,0,,0
192.168.50.112,02:00:00:00:00:12,,43200,$LATER,1,0,0,oldname,0,,0
192.168.50.112,02:00:00:00:00:12,,43200,$LATER,1,0,0,newname,0,,0
EOF

rebuild "4"
expect_hosts "active named leases only, the last line of an address wins, a qualified name also by its first label" \
"192.168.50.101 laptop
192.168.50.106 phone.lan phone
192.168.50.109 forever
192.168.50.111 renewed
192.168.50.112 newname"
[ "$(hups)" = "1" ] && pass "dnsmasq is told once when the file is written" || fail "dnsmasq is told once when the file is written ($(hups))"

rebuild "4"
[ "$(hups)" = "1" ] && pass "an unchanged file is not written again, dnsmasq not told" || fail "an unchanged file is not written again ($(hups))"

cat > "$V6" <<EOF
$H6
fd00:1234:abcd:1::1000,00:01:00:01:aa,43200,$LATER,1,3600,0,1,128,0,0,laptop,02:00:00:00:00:01,0,,1,0,0
fd00:1234:abcd:9::,00:01:00:01:bb,43200,$LATER,1,3600,2,2,56,0,0,router,,0,,1,0,0
fd00:1234:abcd:1::1001,00:01:00:01:cc,43200,$EARLIER,1,3600,0,3,128,0,0,old6,,0,,1,0,0
EOF

rebuild "4 6"
expect_hosts "DHCPv6 addresses join, prefixes and expired leases do not" \
"192.168.50.101 laptop
192.168.50.106 phone.lan phone
192.168.50.109 forever
192.168.50.111 renewed
192.168.50.112 newname
fd00:1234:abcd:1::1000 laptop"
[ "$(hups)" = "2" ] && pass "dnsmasq is told after the change" || fail "dnsmasq is told after the change ($(hups))"

rebuild "6"
expect_hosts "only the daemons that run count" "fd00:1234:abcd:1::1000 laptop"

# What the lease file cleanup leaves: .completed replaces .2 and .1
rm -f "$V6"
printf '%s\n192.168.50.120,02:00:00:00:00:20,,43200,%s,1,0,0,old2,0,,0\n' "$H4" "$LATER" > "$V4.2"
printf '%s\n192.168.50.121,02:00:00:00:00:21,,43200,%s,1,0,0,old1,0,,0\n' "$H4" "$LATER" > "$V4.1"
printf '%s\n192.168.50.101,02:00:00:00:00:01,,43200,%s,1,0,0,laptop,0,,0\n' "$H4" "$LATER" > "$V4"
rebuild "4"
expect_hosts "the files of an LFC run read before the lease file" \
"192.168.50.120 old2
192.168.50.121 old1
192.168.50.101 laptop"
printf '%s\n192.168.50.122,02:00:00:00:00:22,,43200,%s,1,0,0,compact,0,,0\n' "$H4" "$LATER" > "$V4.completed"
rebuild "4"
expect_hosts "a completed LFC replaces its working files" \
"192.168.50.122 compact
192.168.50.101 laptop"

before="$(hups)"
rebuild ""
if [ ! -e "$KDH_HOSTS_FILE" ] && [ "$(hups)" = "$((before + 1))" ]; then
	pass "no Kea running: the file goes, and dnsmasq is told"
else
	fail "no Kea running: the file goes, and dnsmasq is told"
fi
rebuild ""
[ "$(hups)" = "$((before + 1))" ] && pass "no file to remove: dnsmasq not told" || fail "no file to remove: dnsmasq not told"

rm -f "$V4" "$V4.1" "$V4.2" "$V4.completed"
rebuild "4"
expect_hosts "a running Kea without a lease file: a file with no names" ""

KDH_RUNNING="4" sh "$KDH" clear
[ ! -e "$KDH_HOSTS_FILE" ] && pass "clear removes the file" || fail "clear removes the file"

sh "$HOOK" leases4_committed
[ -e "$KDH_RUN_DIR/changed" ] && pass "the hook notes that leases changed" || fail "the hook notes that leases changed"

if sh "$KDH" bogus >/dev/null 2>&1; then
	fail "an unknown command is refused"
else
	pass "an unknown command is refused"
fi

if [ "$FAILED" -eq 0 ]; then
	echo "All kea-dnsmasq-hosts tests passed."
else
	exit 1
fi
