#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Tests of what the owsync patches 050-080 of this feed are for: two owsync
# daemons against each other on this machine (A on 127.0.0.1, B on
# 127.0.0.2), and a peer scripted by hand (peer.py) for what two daemons
# cannot be made to do at a chosen moment.
#
#   OWSYNC="<command>" [OWSYNC_OLD="<command>"] sh tests/owsync/run-tests.sh [test ...]
#
# OWSYNC is how the owsync under test is run: a path, or several words (a
# binary built for a router is run through the image's loader, see
# tests/README.md). OWSYNC_OLD, when given, is an owsync without the patches
# for the tests of a pair with one node upgraded. Without arguments every
# test runs; "list" prints their names.
#
# The tests run in a network and process namespace of their own (bwrap),
# so that their ports and processes are nobody else's. They need python3.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${OWSYNC_TESTS_INSIDE:-}" ] && [ -z "${OWSYNC_TESTS_NO_SANDBOX:-}" ]; then
	if command -v bwrap >/dev/null 2>&1; then
		exec bwrap --unshare-user --unshare-net --unshare-pid --unshare-ipc --die-with-parent \
			--dev-bind / / --proc /proc \
			--setenv OWSYNC_TESTS_INSIDE 1 /bin/sh "$HERE/run-tests.sh" "$@"
	fi
	echo "bwrap is not installed: set OWSYNC_TESTS_NO_SANDBOX=1 to run on this machine's own loopback" >&2
	exit 2
fi

: "${OWSYNC:?set OWSYNC to the command that runs the owsync under test}"
OWSYNC_OLD="${OWSYNC_OLD:-}"
PORT="${OWSYNC_TESTS_PORT:-14321}"
POLL=2
W="$(mktemp -d "${TMPDIR:-/tmp}/owsync-tests.XXXXXX")"
PASS=0; FAIL=0; SKIP=0; FAILED=""

ok()   { PASS=$((PASS + 1)); echo "   ok    $1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED="$FAILED $CURRENT"; echo "   FAIL  $1"; }
skip() { SKIP=$((SKIP + 1)); echo "   skip  $1"; }
# Usage: check <description> <command ...>
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# Usage: wait_for <seconds> <command ...>   true as soon as the command is
wait_for() {
	local n=$(( $1 * 5 )); shift
	while [ "$n" -gt 0 ]; do
		"$@" >/dev/null 2>&1 && return 0
		sleep 0.2; n=$((n - 1))
	done
	return 1
}

addr() { [ "$1" = a ] && echo 127.0.0.1 || echo 127.0.0.2; }
other() { [ "$1" = a ] && echo b || echo a; }
# Usage: mk <node> [key]   an empty node; with a key it encrypts
mk() {
	local n="$1" key="${2:-}"
	rm -rf "$W/$n"; mkdir -p "$W/$n/config" "$W/$n/db"
	printf '#!/bin/sh\necho changed >> "%s/%s/changed"\n' "$W" "$n" > "$W/$n/onchange.sh"
	chmod +x "$W/$n/onchange.sh"
	{
		echo "bind_host=$(addr "$n")"
		echo "port=$PORT"
		echo "sync_dir=$W/$n/config"
		echo "database=$W/$n/db/owsync.db"
		if [ -n "$key" ]; then echo "encryption_key=$key"; else echo "plain_mode=1"; fi
		echo "poll_interval=$POLL"
		echo "log_level=3"
		echo "on_change=$W/$n/onchange.sh"
		echo "peer=$(addr "$(other "$n")"),$(addr "$n")"
		echo "include=*"
	} > "$W/$n/owsync.conf"
	chmod 600 "$W/$n/owsync.conf"
}
# Usage: start <node> [daemon|listen] [command]   listen: accepts, never connects
start() {
	local n="$1" mode="${2:-daemon}" cmd="${3:-$OWSYNC}"
	# shellcheck disable=SC2086
	python3 "$HERE/ptyrun.py" "$W/$n/pid" $cmd "$mode" -c "$W/$n/owsync.conf" >> "$W/$n/log" 2>&1 &
	echo $! > "$W/$n/wrapper"
	wait_for 10 grep -q "Listening on" "$W/$n/log" || echo "   (node $n did not start: $(tail -2 "$W/$n/log" | tr '\n' ' '))"
}
stop() {
	local n="$1" pid
	[ -f "$W/$n/pid" ] || return 0
	pid="$(cat "$W/$n/pid")"
	kill "$pid" 2>/dev/null
	wait_for 3 sh -c "! kill -0 $pid 2>/dev/null" || kill -9 "$pid" 2>/dev/null
	kill "$(cat "$W/$n/wrapper")" 2>/dev/null
	wait "$(cat "$W/$n/wrapper")" 2>/dev/null
	rm -f "$W/$n/pid" "$W/$n/wrapper"
	: > "$W/$n/log.stopped"
}
stop_all() { stop a; stop b; }
# The log of a node since it was last started is all of its log file: mk
# makes the directory anew for every test
has()  { [ "$(cat "$W/$1/config/$2" 2>/dev/null)" = "$3" ]; }
same() { cmp -s "$W/a/config/$1" "$W/b/config/$1"; }
# The date of a file in milliseconds, as owsync reads it
date_ms() { python3 -c 'import os,sys; s=os.lstat(sys.argv[1]); print(s.st_mtime_ns // 1000000)' "$1" 2>/dev/null; }
# Usage: db <node> <path> <field>
db() {
	python3 -c '
import json, sys
try:
    e = json.load(open(sys.argv[1]))["files"][sys.argv[2]]
    v = e[sys.argv[3]]
    print(int(v) if isinstance(v, float) else v)
except Exception:
    print("none")' "$W/$1/db/owsync.db" "$2" "$3"
}
leftovers() { find "$W" \( -name '*.tmp' -o -name '*.db_tmp' \) 2>/dev/null | wc -l; }
# Usage: peer <scenario> [name=value ...]   the scripted peer, as node B to A
peer() { local s="$1"; shift; python3 "$HERE/peer.py" "$s" 127.0.0.1 "$PORT" 127.0.0.2 "$@"; }

t_basic() {
	echo "== a pair in step: an edit goes each way, a deletion goes over"
	mk a; mk b
	echo "one" > "$W/a/config/dhcp"
	start a; start b
	check "a file of A reaches B" wait_for 10 has b dhcp one
	echo "two" > "$W/b/config/firewall"
	check "a file of B reaches A" wait_for 10 has a firewall two
	check "the program after a change ran on both" sh -c "[ -s '$W/a/changed' ] && [ -s '$W/b/changed' ]"
	sleep 1
	rm -f "$W/a/config/dhcp"
	check "a deletion on A removes the file on B" wait_for 10 sh -c "[ ! -e '$W/b/config/dhcp' ]"
	wait_for 5 sh -c "[ \"\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"files\"][\"dhcp\"][\"deleted\"])' '$W/b/db/owsync.db' 2>/dev/null)\" = True ]"
	check "both databases hold the deletion with the same date" [ "$(db a dhcp mtime)" = "$(db b dhcp mtime)" ]
	check "the stamp of a completed session is there on both" sh -c "[ -e '$W/a/db/owsync.db.synced' ] && [ -e '$W/b/db/owsync.db.synced' ]"
	check "no temporary file is left" [ "$(leftovers)" = 0 ]
	stop_all
}

t_retry() {
	echo "== F1: a change made while the peer is out of reach arrives when the peer is back"
	mk a; mk b
	start a
	echo "made while B was away" > "$W/a/config/firewall"
	sleep $((POLL * 2 + 1))
	check "A said once that the session failed and that it is tried again" \
		[ "$(grep -c 'failed: .*tried again' "$W/a/log")" = 1 ]
	# B comes back as a listener: it accepts and never connects, so only
	# A's own retry can bring the file over
	start b listen
	check "the file is on B within three poll intervals of B's return" wait_for $((POLL * 3 + 2)) has b firewall "made while B was away"
	check "A noted the success after its failed attempts" wait_for 3 grep -q "completed after [0-9]* failed attempt" "$W/a/log"
	stop_all
}

t_date() {
	echo "== F6: a second edit right after the first is not undone by the first"
	mk a; mk b
	echo "V1" > "$W/a/config/dhcp"
	t1="$(date_ms "$W/a/config/dhcp")"
	sleep 2   # V1 arrives on B two seconds after its own date
	start a; start b
	wait_for 10 has b dhcp V1
	check "the copy on B has the date of the file on A" [ "$(date_ms "$W/b/config/dhcp")" = "$t1" ]
	check "B's database holds that date" [ "$(db b dhcp mtime)" = "$t1" ]
	# The second edit, dated one second after the first: before B received
	# the first, as with an edit made at once or a clock of A that is behind
	echo "V2" > "$W/a/config/dhcp"
	touch -d "@$(( t1 / 1000 + 1 ))" "$W/a/config/dhcp"
	check "the second edit reaches B" wait_for $((POLL * 3 + 2)) has b dhcp V2
	sleep $((POLL + 1))
	check "and A still holds it" has a dhcp V2
	stop_all
}

t_cut() {
	echo "== F4, F10: a session cut after the first of two files"
	mk a
	start a
	out="$(peer cut-after-first "file=dhcp:from the peer" "file=firewall:also from the peer" age=30)"
	first="$(echo "$out" | sed -n 's/^cut after: //p')"
	[ "$first" = dhcp ] && second=firewall || second=dhcp
	check "the peer sent one file and dropped the connection" [ -n "$first" ]
	check "the file that arrived is in place" wait_for 3 sh -c "[ -s '$W/a/config/$first' ]"
	check "the other one is not" [ ! -e "$W/a/config/$second" ]
	check "the program after a change ran for it" wait_for 5 sh -c "[ -s '$W/a/changed' ]"
	check "the database holds the file that arrived" wait_for 3 sh -c "[ \"\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"files\"][sys.argv[2]][\"deleted\"])' '$W/a/db/owsync.db' '$first' 2>/dev/null)\" = False ]"
	check "A did not take the cut session for a completed one" [ ! -e "$W/a/db/owsync.db.synced" ]
	check "no temporary file is left" [ "$(leftovers)" = 0 ]
	stop_all
}

t_send_fails() {
	echo "== a file that could not be sent is not a session that ended well"
	mk a
	head -c 8000000 /dev/urandom > "$W/a/config/big"
	start a
	sleep 1
	# The peer asks for the file, says at once that it is done, and drops
	# the connection while the daemon is still sending
	peer take-and-drop want=big >/dev/null
	check "the daemon noticed that the session failed" wait_for 10 grep -q "Session error" "$W/a/log"
	check "and did not take it for a completed one" [ ! -e "$W/a/db/owsync.db.synced" ]
	stop_all
}

t_content() {
	echo "== F5: content that is not what was announced, and a file nobody asked for"
	mk a
	start a
	peer wrong-content "file=dhcp:what was announced" age=30 >/dev/null
	sleep 1
	check "content that does not match the announced hash is not written" [ ! -e "$W/a/config/dhcp" ]
	check "A says why" grep -q "is not what the peer announced" "$W/a/log"
	peer unasked "file=network:pushed" >/dev/null
	sleep 1
	check "a file that was not asked for is not written" [ ! -e "$W/a/config/network" ]
	check "the program after a change did not run" [ ! -s "$W/a/changed" ]
	stop_all
}

t_edit_during() {
	echo "== F2: edits made on this node while a session runs"
	mk a
	echo "old" > "$W/a/config/dhcp"; touch -d '100 seconds ago' "$W/a/config/dhcp"
	start a
	sleep 1
	peer hold "file=dhcp:from the peer" age=50 "ready=$W/ready" "go=$W/go" > "$W/peer.out" 2>&1 &
	ppid=$!
	wait_for 10 [ -e "$W/ready" ]
	# A has compared and asked for dhcp. Now, before it arrives:
	echo "edited here meanwhile" > "$W/a/config/dhcp"
	echo "another file, edited meanwhile" > "$W/a/config/firewall"
	: > "$W/go"
	wait "$ppid"
	sleep 1
	check "the file edited here during the session is not replaced" has a dhcp "edited here meanwhile"
	check "A says the next session compares it again" grep -q "changed here since this session's scan" "$W/a/log"
	# B comes back as a listener: both edits must be offered by A's poller
	mk b
	start b listen
	check "the other file edited meanwhile reaches the peer" wait_for $((POLL * 3 + 2)) has b firewall "another file, edited meanwhile"
	check "and so does the edit of the first" wait_for $((POLL * 3 + 2)) has b dhcp "edited here meanwhile"
	stop_all
	rm -f "$W/ready" "$W/go"
}

t_together() {
	echo "== F3: both nodes start at the same moment, each with a large file for the other (8 rounds)"
	notsync=0; errors=0; i=0
	while [ "$i" -lt 8 ]; do
		mk a; mk b
		head -c 300000 /dev/urandom | od -An -x | head -c 400000 > "$W/a/config/dhcp"
		head -c 300000 /dev/urandom | od -An -x | head -c 400000 > "$W/b/config/firewall"
		start a & start b & wait
		if ! wait_for 12 sh -c "cmp -s '$W/a/config/dhcp' '$W/b/config/dhcp' && cmp -s '$W/a/config/firewall' '$W/b/config/firewall'"; then
			notsync=$((notsync + 1))
		fi
		errors=$(( errors + $(cat "$W/a/log" "$W/b/log" | grep -cE "Write failed|rename|Short read|Cannot save database") ))
		stop_all
		i=$((i + 1))
	done
	check "every round ended in step within 12 s" [ "$notsync" = 0 ]
	check "no write or database error in any round" [ "$errors" = 0 ]
	check "no temporary file is left" [ "$(leftovers)" = 0 ]
}

t_database() {
	echo "== F9: the database"
	mk a; mk b
	echo "one" > "$W/a/config/dhcp"
	start a; start b
	wait_for 10 has b dhcp one
	check "the database is written under its own name only" [ "$(ls "$W/a/db" | grep -vcE '^owsync\.db(\.synced|\.lock)?$')" = 0 ]
	rm -rf "$W/a/db"
	echo "two" > "$W/a/config/dhcp"
	check "a database directory that went missing is made again" wait_for $((POLL * 3)) [ -s "$W/a/db/owsync.db" ]
	check "and the edit still reaches B" wait_for $((POLL * 3 + 2)) has b dhcp two
	stop_all
}

t_future() {
	echo "== F7: a file dated in the future"
	mk a; mk b
	echo "written while the clock was wrong" > "$W/a/config/dhcp"
	touch -d '400 days' "$W/a/config/dhcp"
	now="$(date +%s)"
	start a; start b
	wait_for 10 has b dhcp "written while the clock was wrong"
	da="$(date_ms "$W/a/config/dhcp")"
	check "its date on A is the present after the first session" [ "$(( da / 1000 ))" -le "$(( now + 60 ))" ]
	check "B holds it with the same date" [ "$(date_ms "$W/b/config/dhcp")" = "$da" ]
	sleep 1
	echo "edited on B afterwards" > "$W/b/config/dhcp"
	check "a later edit on B wins over it" wait_for $((POLL * 3 + 2)) has a dhcp "edited on B afterwards"
	stop_all
}

t_large() {
	echo "== a file too large to be sent"
	mk a; mk b
	head -c 17000000 /dev/zero > "$W/a/config/huge"
	# Under half the message size by sixteen bytes: its content as hex
	# fits a message, the message around it does not
	head -c 16777200 /dev/zero > "$W/a/config/edge"
	echo "small" > "$W/a/config/dhcp"
	start a; start b
	check "the small file next to it reaches B" wait_for 15 has b dhcp small
	check "the large file is not on B" [ ! -e "$W/b/config/huge" ]
	check "nor the one just under half the message size" [ ! -e "$W/b/config/edge" ]
	check "A says of both that they are too large and not offered" [ "$(grep -c "too large to sync.*Not offered" "$W/a/log")" -ge 2 ]
	check "the session still counts as complete on A" wait_for 5 [ -e "$W/a/db/owsync.db.synced" ]
	check "and on B" wait_for 5 [ -e "$W/b/db/owsync.db.synced" ]
	stop_all
}

t_encrypted() {
	echo "== an encrypting pair, and the one-shot session of a joining node"
	# shellcheck disable=SC2086
	key="$($OWSYNC genkey 2>/dev/null | tail -1)"
	mk a "$key"; mk b "$key"
	echo "one" > "$W/a/config/dhcp"
	start a
	# The one-shot session ha-cluster runs for a router that joins
	# shellcheck disable=SC2086
	$OWSYNC connect "127.0.0.1,127.0.0.2" -c "$W/b/owsync.conf" > "$W/b/connect.out" 2>&1
	check "the one-shot session ends well" [ "$?" = 0 ]
	check "it took A's file" has b dhcp one
	check "and left the stamp of a completed session" [ -e "$W/b/db/owsync.db.synced" ]
	start b
	echo "two" > "$W/b/config/firewall"
	check "an edit on B reaches A afterwards" wait_for $((POLL * 3 + 2)) has a firewall two
	stop_all
	# Two nodes with different keys: nothing crosses, and the log says
	# what is wrong, not that the peer is busy
	# shellcheck disable=SC2086
	other="$($OWSYNC genkey 2>/dev/null | tail -1)"
	mk a "$key"; mk b "$other"
	echo "of A" > "$W/a/config/dhcp"
	start a; start b
	check "with another key the log names the key" wait_for 10 sh -c "cat '$W/a/log' '$W/b/log' | grep -q 'cannot be decrypted'"
	sleep $((POLL + 1))
	check "and nothing crosses" [ ! -e "$W/b/config/dhcp" ]
	stop_all
}

t_mixed() {
	echo "== a pair with one node upgraded (A new, B without the patches)"
	if [ -z "$OWSYNC_OLD" ]; then skip "OWSYNC_OLD is not set"; return; fi
	mk a; mk b
	echo "one" > "$W/a/config/dhcp"
	start a; start b daemon "$OWSYNC_OLD"
	check "a file of the new node reaches the old one" wait_for 10 has b dhcp one
	sleep 1
	echo "two" > "$W/b/config/firewall"
	check "a file of the old node reaches the new one" wait_for $((POLL * 3 + 2)) has a firewall two
	check "and keeps the old node's date there" [ "$(date_ms "$W/a/config/firewall")" = "$(date_ms "$W/b/config/firewall")" ]
	sleep 1
	rm -f "$W/b/config/dhcp"
	check "a deletion on the old node removes the file on the new one" wait_for $((POLL * 3 + 2)) sh -c "[ ! -e '$W/a/config/dhcp' ]"
	stop b
	echo "made while the old node was away" > "$W/a/config/network"
	sleep $((POLL + 1))
	start b listen "$OWSYNC_OLD"
	check "a change made while the old node was away arrives when it is back" wait_for $((POLL * 3 + 2)) has b network "made while the old node was away"
	stop_all
	# The old node announces every file, also one it cannot send: the
	# new node does not ask for it, and its sessions are complete
	mk a; mk b
	head -c 17000000 /dev/zero > "$W/b/config/huge"
	echo "next to it" > "$W/b/config/dhcp"
	start b daemon "$OWSYNC_OLD"; start a
	check "next to a file the old node cannot send, its other file arrives" wait_for 15 has a dhcp "next to it"
	check "the new node does not ask for the large one" grep -q "too large to be sent.*not asked for" "$W/a/log"
	check "and its session with the old node is complete" wait_for 5 [ -e "$W/a/db/owsync.db.synced" ]
	stop_all
	# Both start at the same moment: the new node turns the old one's
	# session away while its own runs, and its own brings both files over
	mk a; mk b
	echo "from A" > "$W/a/config/dhcp"; echo "from B" > "$W/b/config/firewall"
	start a & start b daemon "$OWSYNC_OLD" & wait
	check "started together, both files are on both" wait_for 12 sh -c "cmp -s '$W/a/config/dhcp' '$W/b/config/dhcp' && cmp -s '$W/a/config/firewall' '$W/b/config/firewall'"
	stop_all
}

ALL="basic retry date cut send_fails content edit_during together database future large encrypted mixed"
[ "${1:-}" = list ] && { echo "$ALL"; rm -rf "$W"; exit 0; }
[ $# -gt 0 ] || set -- $ALL
# shellcheck disable=SC2086
echo "# owsync under test: $($OWSYNC --version 2>&1 | head -1)${OWSYNC_OLD:+; without the patches: $($OWSYNC_OLD --version 2>&1 | head -1)}"
for CURRENT in "$@"; do
	case " $ALL " in
		*" $CURRENT "*) "t_$CURRENT" ;;
		*) echo "no such test: $CURRENT"; FAIL=$((FAIL + 1)) ;;
	esac
	stop_all
done
echo
echo "passed $PASS, failed $FAIL, skipped $SKIP${FAILED:+ (failed in:$(echo "$FAILED" | tr ' ' '\n' | sort -u | tr '\n' ' '))}"
if [ "$FAIL" -eq 0 ] && [ -z "${OWSYNC_TESTS_KEEP:-}" ]; then rm -rf "$W"; else echo "work directory kept: $W"; fi
[ "$FAIL" -eq 0 ]
