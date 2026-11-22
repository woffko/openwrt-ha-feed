#!/bin/sh
# SPDX-License-Identifier: MIT
#
# ha_ensure_run_dir: the run directory of ha-cluster, which holds generated
# configs with keys, made root's alone (0700) whoever made it first, and
# never followed as a link. Runs the library against a temporary root with
# empty stand-ins for /lib/functions.sh, without a router.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
TEST_ROOT="$(mktemp -d)"
FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT/root/lib/config"
: > "$TEST_ROOT/root/lib/functions.sh"
: > "$TEST_ROOT/root/lib/config/uci.sh"
export IPKG_INSTROOT="$TEST_ROOT/root"
export HA_CLUSTER_RUN_DIR="$TEST_ROOT/run/ha-cluster"
. "$REPO_ROOT/ha-cluster/files/ha-cluster.sh"

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; FAILED=1; }
mode() { ls -ld "$1" | cut -c1-10; }

ha_ensure_run_dir && [ "$(mode "$HA_CLUSTER_RUN_DIR")" = "drwx------" ] &&
	pass "made 0700 when missing" || fail "made 0700 when missing ($(mode "$HA_CLUSTER_RUN_DIR"))"

rm -rf "$HA_CLUSTER_RUN_DIR"
mkdir -p "$HA_CLUSTER_RUN_DIR/sub"
chmod 0755 "$HA_CLUSTER_RUN_DIR"
ha_ensure_run_dir && [ "$(mode "$HA_CLUSTER_RUN_DIR")" = "drwx------" ] &&
	pass "made 0700 when a helper left it 0755" || fail "made 0700 when a helper left it 0755 ($(mode "$HA_CLUSTER_RUN_DIR"))"

rm -rf "$HA_CLUSTER_RUN_DIR"
mkdir -p "$TEST_ROOT/elsewhere"
ln -s "$TEST_ROOT/elsewhere" "$HA_CLUSTER_RUN_DIR"
ha_ensure_run_dir && [ ! -L "$HA_CLUSTER_RUN_DIR" ] && [ -d "$HA_CLUSTER_RUN_DIR" ] &&
	pass "a link is replaced by a directory" || fail "a link is replaced by a directory"

if [ "$FAILED" -eq 0 ]; then
	echo "All ha-cluster run directory tests passed."
else
	exit 1
fi
