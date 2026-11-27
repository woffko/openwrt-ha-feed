# A router added to a working cluster (option sync_join). owsync keeps the
# copy of a file that was changed last, and a router just set up has the
# newer files: its first sync would replace the configuration of the
# working node. With sync_join the service starts owsync through the join
# program, which gives the node's copies an old date and holds one session
# with the peer before the daemon runs; the option clears itself, and it is
# refused on a node that has completed a session with a peer before (the
# stamp owsync 1.3.0-r7 leaves next to its database).
# The peer here is a second owsync daemon on 127.0.0.2, with a directory
# of its own: the sessions are real ones.
uci set ha-cluster.config.sync_join=1
uci set ha-cluster.config.bind_address=127.0.0.1
uci set ha-cluster.peer1.address=127.0.0.2
uci set ha-cluster.peer1.source_address=127.0.0.1

case_after() {
	P=/tmp/peer
	real="$OWSYNC_BIN"
	month_ago=$(( $(date +%s) - 2592000 ))
	peer_start() { # the peer anew: the production file, a month old, no record
		[ -n "$peer_pid" ] && { kill "$peer_pid" 2>/dev/null; wait "$peer_pid" 2>/dev/null; }
		rm -rf "$P"; mkdir -p "$P/config" "$P/db"
		{
			echo "bind_host=127.0.0.2"
			echo "port=4321"
			echo "sync_dir=$P/config"
			echo "database=$P/db/owsync.db"
			echo "poll_interval=30"
			echo "log_level=0"
			grep '^encryption_key=' "$OWSYNC_CONF"
			# A daemon wants a peer; nothing listens there, the sessions
			# of this case are started by the new node
			echo "peer=127.0.0.1"
			echo "include=dhcp"
		} > "$P/owsync.conf"
		chmod 600 "$P/owsync.conf"
		echo "# production: 40 static leases" > "$P/config/dhcp"
		touch -d "@$month_ago" "$P/config/dhcp"
		"$real" daemon -c "$P/owsync.conf" >/dev/null 2>&1 &
		peer_pid=$!
		sleep 2
	}
	files() {
		echo "   this node holds: $(head -n 1 /etc/config/dhcp)"
		echo "   the peer holds:  $(head -n 1 "$P/config/dhcp")"
	}
	peer_kept() { echo "   the peer's copy still has its date: $([ "$(date -r "$P/config/dhcp" +%s)" = "$month_ago" ] && echo yes || echo no)"; }
	state() {
		echo "   option: $(uci -q get ha-cluster.config.sync_join || echo unset)," \
			"stamp of a completed session: $([ -e "$HA_OWSYNC_SYNCED" ] && echo there || echo none)," \
			"database: $(grep -q mtime "$HA_OWSYNC_DB" 2>/dev/null && echo "holds files" || echo none)," \
			"note: $(cut -d' ' -f1-2 "$HA_OWSYNC_JOIN_NOTE" 2>/dev/null | sed 's/ [0-9]*$//')," \
			"status says: $(/usr/libexec/rpcd/ha-cluster call status 2>/dev/null | jsonfilter -e '@.sync_join' 2>/dev/null || echo nothing)"
	}
	said() { grep -o 'Config sync: .*' "$CHAR_LOG" | cut -c1-100 | sed 's/^/   log: /'; : > "$CHAR_LOG"; }
	# A start of the service is a new process: here the option read at
	# the load before would stay
	reload() { unset CONFIG_config_sync_join; config_load ha-cluster; }
	# The join program, bounded: it tries for ever by design
	run_join() {
		( OWSYNC_BIN=/tmp/ow; HA_OWSYNC_JOIN_RETRY=1; ha_owsync_join_run 2>/dev/null ) &
		join_pid=$!
		( sleep 30; kill "$join_pid" 2>/dev/null ) &
		guard_pid=$!
		wait "$join_pid"
		kill "$guard_pid" 2>/dev/null
	}
	printf '#!/bin/sh\n[ "$1" = daemon ] && { echo "   becomes: owsync $*"; exit 0; }\nexec %s "$@"\n' "$real" > /tmp/ow
	chmod +x /tmp/ow

	echo "== after the start: owsync is started through the join program (above)"
	state

	echo "== without the option: the newer copy wins, and the new node has it"
	peer_start
	echo "# factory default" > /etc/config/dhcp
	"$real" connect 127.0.0.2,127.0.0.1 -c "$OWSYNC_CONF" >/dev/null 2>&1
	echo "   session rc=$?"
	# The peer writes what it took a moment after the session is over
	i=0
	while [ "$i" -lt 10 ] && grep -q production "$P/config/dhcp"; do sleep 1; i=$((i + 1)); done
	files
	echo "   the session left the stamp on this node: $([ -e "$HA_OWSYNC_SYNCED" ] && echo yes || echo no)"
	rm -f "$HA_OWSYNC_DB" "$HA_OWSYNC_SYNCED"

	echo "== the node's copies get an old date: the synced files, no others"
	echo "# factory default" > /etc/config/dhcp
	touch /etc/config/network
	ha_owsync_join_age
	echo "   rc=$?"
	echo "   dhcp (synced): $(date -u -r /etc/config/dhcp +%F)"
	echo "   network (excluded): $([ "$(date -u -r /etc/config/network +%Y)" -gt 2020 ] && echo "its own date")"

	echo "== owsync ran here once and reached nobody: a database, yet not a node that has synced"
	kill "$peer_pid" 2>/dev/null; wait "$peer_pid" 2>/dev/null; peer_pid=""
	"$real" daemon -c "$OWSYNC_CONF" >/dev/null 2>&1 &
	own_pid=$!
	sleep 3
	kill "$own_pid" 2>/dev/null; wait "$own_pid" 2>/dev/null
	reload
	ha_owsync_join_prepare
	echo "   the join is accepted: rc=$?"
	state

	echo "== a list of files that cannot be had: no session is held"
	peer_start
	echo "# factory default" > /etc/config/dhcp
	printf '#!/bin/sh\n[ "$1" = scan ] && exit 1\nexec %s "$@"\n' "$real" > /tmp/ow-noscan
	chmod +x /tmp/ow-noscan
	( OWSYNC_BIN=/tmp/ow-noscan; ha_owsync_join_once >/dev/null 2>&1; echo "   rc=$?" )
	sleep 2
	files
	said

	echo "== with sync_join: one attempt"
	echo "# factory default" > /etc/config/dhcp
	ha_owsync_join_once >/dev/null 2>&1
	echo "   rc=$? peer=$_ha_owsync_joined"
	files
	peer_kept
	rm -f "$HA_OWSYNC_DB" "$HA_OWSYNC_SYNCED"

	echo "== the join program to its end; the file was changed on this node meanwhile"
	echo "# changed on the new node while it waited" > /etc/config/dhcp
	run_join
	files
	peer_kept
	state
	said

	echo "== procd starts the program again later (the daemon ended): no second join"
	echo "# changed on this node after the join" > /etc/config/dhcp
	run_join
	echo "   this node holds: $(head -n 1 /etc/config/dhcp), dated $([ "$(date -u -r /etc/config/dhcp +%Y)" -gt 2020 ] && echo now || echo 2000)"
	said

	echo "== sync_join on a node that has synced before: refused"
	uci set ha-cluster.config.sync_join=1; uci commit ha-cluster
	reload
	echo "# the working configuration of this node" > /etc/config/dhcp
	ha_owsync_join_prepare
	echo "   rc=$?"
	echo "   this node holds: $(head -n 1 /etc/config/dhcp), dated $([ "$(date -u -r /etc/config/dhcp +%Y)" -gt 2020 ] && echo now || echo 2000)"
	state
	said

	echo "== a LuCI apply not confirmed yet holds the join back"
	HA_UCI_SNAPSHOT_DIR=/tmp/snap; mkdir -p /tmp/snap
	_ha_uci_apply_pending && echo "   pending" || echo "   not pending"
	: > /tmp/snap/ha-cluster
	_ha_uci_apply_pending && echo "   pending" || echo "   not pending"

	kill "$peer_pid" 2>/dev/null; wait "$peer_pid" 2>/dev/null
	rm -rf "$P" /tmp/snap /tmp/ow /tmp/ow-noscan
	: > "$CHAR_LOG"
}
