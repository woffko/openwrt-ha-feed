#!/bin/sh
# SPDX-License-Identifier: MIT
#
# owsync-changed, run by owsync (on_change) after a sync session changed
# files: reload_config is run once for a burst of sessions, and once more
# for a session that came while it ran; a run that finds the lock held
# leaves the work to the holder.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
OC="$REPO_ROOT/ha-cluster/files/owsync-changed.sh"
TEST_ROOT="$(mktemp -d)"
FAILED=0
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

export HA_OWSYNC_CHANGED_LOCK="$TEST_ROOT/lock"
export HA_OWSYNC_CHANGED_PENDING="$TEST_ROOT/pending"
export HA_RELOAD_CONFIG_BIN="$TEST_ROOT/reload_config"
mkdir -p "$TEST_ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/bin/logger"
chmod +x "$TEST_ROOT/bin/logger"
export PATH="$TEST_ROOT/bin:$PATH"

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; FAILED=1; }
runs() { cat "$TEST_ROOT/runs" 2>/dev/null | wc -l | tr -d ' '; }

# reload_config takes a second, and counts its runs
cat > "$HA_RELOAD_CONFIG_BIN" <<EOS
#!/bin/sh
echo run >> "$TEST_ROOT/runs"
sleep 1
EOS
chmod +x "$HA_RELOAD_CONFIG_BIN"

HA_OWSYNC_SETTLE=0 sh "$OC"
[ "$(runs)" = "1" ] && pass "one session: reload_config once" || fail "one session: reload_config once ($(runs))"
[ ! -e "$HA_OWSYNC_CHANGED_PENDING" ] && pass "nothing left pending" || fail "nothing left pending"

# A burst: the first run settles for 2 s; three more arrive meanwhile
rm -f "$TEST_ROOT/runs"
HA_OWSYNC_SETTLE=2 sh "$OC" &
first=$!
sleep 0.5
for i in 1 2 3; do HA_OWSYNC_SETTLE=2 sh "$OC"; done
wait "$first"
[ "$(runs)" = "1" ] && pass "a burst during the pause: reload_config once" || fail "a burst during the pause: reload_config once ($(runs))"

# A session while reload_config runs: one more run after it
rm -f "$TEST_ROOT/runs"
HA_OWSYNC_SETTLE=0 sh "$OC" &
first=$!
sleep 0.5
HA_OWSYNC_SETTLE=0 sh "$OC"
wait "$first"
[ "$(runs)" = "2" ] && pass "a session while reload_config runs: one more run" || fail "a session while reload_config runs: one more run ($(runs))"
[ ! -e "$HA_OWSYNC_CHANGED_PENDING" ] && pass "nothing left pending after the burst" || fail "nothing left pending after the burst"

# reload_config failing: the run ends, nothing pending
rm -f "$TEST_ROOT/runs"
printf '#!/bin/sh\necho run >> "%s/runs"\nexit 1\n' "$TEST_ROOT" > "$HA_RELOAD_CONFIG_BIN"
HA_OWSYNC_SETTLE=0 sh "$OC"
[ "$(runs)" = "1" ] && [ ! -e "$HA_OWSYNC_CHANGED_PENDING" ] && pass "a failing reload_config is run once" || fail "a failing reload_config is run once"

[ "$FAILED" -eq 0 ] && echo "All owsync-changed tests passed." || exit 1
