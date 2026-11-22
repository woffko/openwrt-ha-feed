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
export KDH_ETC_HOSTS="$TEST_ROOT/hosts-file"
mkdir -p "$KDH_KEA_LEASE_DIR" "$KDH_KEA_CONF_DIR"
printf '127.0.0.1 localhost\n192.168.50.1 router.lan router\n192.168.50.5 NAS.lan nas # static\n' > "$KDH_ETC_HOSTS"

# A stand-in for uci: "show dhcp" prints $UCI_DHCP when it exists, anything
# else prints nothing
export UCI_DHCP="$TEST_ROOT/uci-dhcp"
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1 $2" = "show dhcp" ] && [ -r "$UCI_DHCP" ] && cat "$UCI_DHCP"
exit 0
EOF
chmod +x "$TEST_ROOT/bin/uci"
export PATH="$TEST_ROOT/bin:$PATH"

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
192.168.50.113,02:00:00:00:00:13,,43200,$LATER,1,1,1,updates.example.org.,0,,0
192.168.50.114,02:00:00:00:00:14,,43200,$LATER,1,0,0,nas,0,,0
192.168.50.115,02:00:00:00:00:15,,43200,$LATER,1,0,0,Router,0,,0
192.168.50.116,02:00:00:00:00:16,,43200,$LATER,1,0,0,wpad,0,,0
192.168.50.117,02:00:00:00:00:17,,43200,$LATER,1,0,0,LAPTOP,0,,0
192.168.50.118,02:00:00:00:00:18,,43200,$LATER,1,0,0,a123456789012345678901234567890123456789012345678901234567890123,0,,0
EOF

rebuild "4"
expect_hosts "active leases, the last line of an address wins, only the first label of a name, no name that is taken or claimed before, no label over 63" \
"192.168.50.101 laptop
192.168.50.106 phone
192.168.50.109 forever
192.168.50.111 renewed
192.168.50.112 newname
192.168.50.113 updates"
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
192.168.50.106 phone
192.168.50.109 forever
192.168.50.111 renewed
192.168.50.112 newname
192.168.50.113 updates
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

# Static leases of /etc/config/dhcp: the name is the host's, by its address
# or one of its MACs (any case); a 'domain' name stays taken
cat > "$UCI_DHCP" <<'EOF'
dhcp.cfg01=host
dhcp.cfg01.name='printer'
dhcp.cfg01.ip='192.168.50.120'
dhcp.cfg01.mac='02:00:00:00:00:30'
dhcp.cfg02=host
dhcp.cfg02.name='Camera'
dhcp.cfg02.mac='02:00:00:00:00:31' '02:00:00:00:00:3A'
dhcp.cfg03=host
dhcp.cfg03.name='scanner'
dhcp.cfg03.ip='192.168.50.125'
dhcp.cfg04=domain
dhcp.cfg04.name='files'
dhcp.cfg04.ip='192.168.50.7'
EOF
rm -f "$V4.1" "$V4.2" "$V4.completed"
cat > "$V4" <<EOF
$H4
192.168.50.130,02:00:00:00:00:99,,43200,$LATER,1,0,0,printer,0,,0
192.168.50.120,02:00:00:00:00:30,,43200,$LATER,1,0,0,printer,0,,0
192.168.50.131,02:00:00:00:00:3a,,43200,$LATER,1,0,0,camera,0,,0
192.168.50.125,02:00:00:00:00:40,,43200,$LATER,1,0,0,scanner,0,,0
192.168.50.132,02:00:00:00:00:41,,43200,$LATER,1,0,0,files,0,,0
192.168.50.133,02:00:00:00:00:42,,43200,$LATER,1,0,0,Scanner,0,,0
EOF
cat > "$V6" <<EOF
$H6
fd00:1234:abcd:1::1200,00:01:00:01:dd,43200,$LATER,1,3600,0,1,128,0,0,printer,02:00:00:00:00:30,0,,1,0,0
fd00:1234:abcd:1::1201,00:01:00:01:ee,43200,$LATER,1,3600,0,1,128,0,0,camera,,0,,1,0,0
EOF
rebuild "4 6"
expect_hosts "a static lease name for that host's lease only (address or MAC), a domain name never" \
"192.168.50.120 printer
192.168.50.131 camera
192.168.50.125 scanner
fd00:1234:abcd:1::1200 printer"
rm -f "$UCI_DHCP" "$V6"

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
[ ! -e "$KDH_RUN_DIR/changed" ] && pass "the hook writes nothing before the service made its directory" || fail "the hook writes nothing before the service made its directory"
mkdir -p "$KDH_RUN_DIR"
sh "$HOOK" leases4_committed
[ -e "$KDH_RUN_DIR/changed" ] && pass "the hook notes that leases changed" || fail "the hook notes that leases changed"
mkdir -p "$TEST_ROOT/elsewhere"
rm -rf "$KDH_RUN_DIR"
ln -s "$TEST_ROOT/elsewhere" "$KDH_RUN_DIR"
sh "$HOOK" leases4_committed
[ ! -e "$TEST_ROOT/elsewhere/changed" ] && pass "the hook writes nothing through a link" || fail "the hook writes nothing through a link"

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
