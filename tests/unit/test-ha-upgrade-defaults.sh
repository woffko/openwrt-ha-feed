#!/bin/sh
# SPDX-License-Identifier: MIT
#
# The uci-defaults script of ha-cluster: the IPv6 BACKUP guard handler a
# sysupgrade brought back from the previous image, the handlers of earlier
# releases, the name of the advanced section and the persist interval. Runs
# the script against a temporary root and stand-ins for uci and
# /lib/functions.sh, without a router.
#
# The migration to the sync group model needs a real uci: it is covered by
# tests/characterization/migration (scenario 24, or
# tests/scripts/run-characterization-rootless.sh).

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
TEST_ROOT="$(mktemp -d)"
HOOKS="$TEST_ROOT/etc/hotplug.d/keepalived"
GUARD="$TEST_ROOT/usr/lib/ha-cluster/ipv6-backup-guard"
CONFIG_DIR="$TEST_ROOT/etc/config"
UCI_STATE="$TEST_ROOT/uci-show"
SCRIPT="$TEST_ROOT/60_ha-cluster-sync-model"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

# The script under test, with its three absolute paths moved under TEST_ROOT
sed -e "s|^HOOKS=\"/etc/hotplug.d/keepalived\"\$|HOOKS=\"$HOOKS\"|" \
	-e "s|^GUARD=\"/usr/lib/ha-cluster/ipv6-backup-guard\"\$|GUARD=\"$GUARD\"|" \
	-e "s|^\. /lib/functions.sh\$|. \"$TEST_ROOT/functions.sh\"|" \
	"$REPO_ROOT/ha-cluster/files/ha-cluster.uci-defaults" > "$SCRIPT"
grep -Fxq "HOOKS=\"$HOOKS\"" "$SCRIPT"
grep -Fxq "GUARD=\"$GUARD\"" "$SCRIPT"
grep -Fxq ". \"$TEST_ROOT/functions.sh\"" "$SCRIPT"

# /lib/functions.sh: the config functions the script uses, on the data of
# the uci stand-in below. The states of this test hold no sync group and no
# peer, so the migration steps iterating them find nothing to do.
cat > "$TEST_ROOT/functions.sh" <<'EOF'
config_load() { :; }

config_foreach() {
	local _cf_fn="$1" _cf_type="$2" _cf_section

	for _cf_section in $(awk -F'[.=]' -v type="$_cf_type" \
		'NF == 3 && $3 == type { print $2 }' "$UCI_STATE"); do
		"$_cf_fn" "$_cf_section"
	done
}

config_get() {
	local _cg_value

	_cg_value="$(uci -q get "ha-cluster.$2.$3")" || _cg_value="${4:-}"
	eval "$1=\$_cg_value"
}
EOF

# Stand-in for uci on the output format of "uci show": enough for get of a
# section, show, rename of a section, delete of an option and commit.
uci() {
	[ "$1" = "-q" ] && shift
	case "$1" in
		get)
			awk -v key="$2" 'index($0, key "=") == 1 {
				print substr($0, length(key) + 2); found = 1
			} END { exit !found }' "$UCI_STATE" ;;
		show)
			cat "$UCI_STATE" ;;
		rename)
			awk -v old="${2%%=*}" -v new="ha-cluster.${2#*=}" '{
				if (index($0, old "=") == 1 || index($0, old ".") == 1)
					print new substr($0, length(old) + 1)
				else
					print
			}' "$UCI_STATE" > "$UCI_STATE.new"
			mv "$UCI_STATE.new" "$UCI_STATE" ;;
		delete)
			awk -v key="$2" 'index($0, key "=") != 1' "$UCI_STATE" > "$UCI_STATE.new"
			mv "$UCI_STATE.new" "$UCI_STATE" ;;
		commit)
			echo commit >> "$TEST_ROOT/commits" ;;
	esac
}

# OpenWrt sources the script in a subshell, at first boot and from the
# package postinst, without errexit or nounset
run_script() {
	(
		set +eu
		export UCI_CONFIG_DIR="$CONFIG_DIR"
		. "$SCRIPT"
	)
}

reset_root() {
	rm -rf "$TEST_ROOT/etc" "$TEST_ROOT/usr" "$TEST_ROOT/commits"
	mkdir -p "$HOOKS" "$(dirname "$GUARD")" "$CONFIG_DIR"
	printf '#!/bin/sh\n# guard of this release\n' > "$GUARD"
	: > "$CONFIG_DIR/ha-cluster"
	cat > "$UCI_STATE" <<-'EOF'
		ha-cluster.config=global
		ha-cluster.config.enabled='1'
		ha-cluster.@advanced[0]=advanced
		ha-cluster.@advanced[0].log_level='3'
		ha-cluster.@advanced[0].lease_sync_persist_interval='60'
	EOF
}

fail() {
	echo "not ok - $1" >&2
	exit 1
}

expect() {
	label="$1"
	shift
	"$@" || fail "$label"
}

refute() {
	label="$1"
	shift
	if "$@"; then
		fail "$label"
	fi
}

# ------------------------------------------------------------------
reset_root
printf '#!/bin/sh\n# guard of the previous image\n' > "$HOOKS/20-ipv6-backup-guard"
chmod 0644 "$HOOKS/20-ipv6-backup-guard"
printf '#!/bin/sh\n# legacy\n' > "$HOOKS/20-dhcpv6-backup-guard"
printf '#!/bin/sh\n# legacy\n' > "$HOOKS/21-RA-backup-guard"
printf '#!/bin/sh\n# custom hook\n' > "$HOOKS/50-custom"
expect 'the script succeeds' run_script
expect 'the handler of this release is back' cmp -s "$GUARD" "$HOOKS/20-ipv6-backup-guard"
expect 'the restored handler is executable' [ -x "$HOOKS/20-ipv6-backup-guard" ]
refute 'the DHCPv6 handler of earlier releases is gone' [ -e "$HOOKS/20-dhcpv6-backup-guard" ]
refute 'the RA handler of earlier releases is gone' [ -e "$HOOKS/21-RA-backup-guard" ]
expect 'a custom hook is left alone' grep -Fxq '# custom hook' "$HOOKS/50-custom"
echo 'ok - a handler kept from the previous image is replaced and the earlier ones removed'

# ------------------------------------------------------------------
reset_root
cp "$GUARD" "$HOOKS/20-ipv6-backup-guard"
# Backdated, with a marker dated after it: a rewrite would make the handler
# the newer of the two
touch -d '2001-01-01 00:00:00' "$HOOKS/20-ipv6-backup-guard"
touch -d '2002-01-01 00:00:00' "$TEST_ROOT/marker"
run_script
expect 'an up-to-date handler is not rewritten' [ "$TEST_ROOT/marker" -nt "$HOOKS/20-ipv6-backup-guard" ]
echo 'ok - an up-to-date handler is left untouched'

reset_root
rmdir "$HOOKS"
run_script
expect 'the handler is installed into a missing directory' cmp -s "$GUARD" "$HOOKS/20-ipv6-backup-guard"
echo 'ok - a missing hooks directory is created'

reset_root
rm -f "$GUARD"
printf '#!/bin/sh\n# guard of the previous image\n' > "$HOOKS/20-ipv6-backup-guard"
printf '#!/bin/sh\n# legacy\n' > "$HOOKS/21-RA-backup-guard"
expect 'the script succeeds without a packaged handler' run_script
expect 'the handler in place is kept' grep -Fxq '# guard of the previous image' "$HOOKS/20-ipv6-backup-guard"
refute 'the earlier handler is removed all the same' [ -e "$HOOKS/21-RA-backup-guard" ]
echo 'ok - without a packaged copy the handler in place is kept'

# ------------------------------------------------------------------
reset_root
run_script
expect 'the anonymous advanced section is named' grep -Fxq 'ha-cluster.advanced=advanced' "$UCI_STATE"
expect 'its options follow' grep -Fxq "ha-cluster.advanced.log_level='3'" "$UCI_STATE"
refute 'no anonymous advanced section is left' grep -Fq '@advanced[0]' "$UCI_STATE"
refute 'the persist interval is dropped' grep -Fq 'lease_sync_persist_interval' "$UCI_STATE"
expect 'the change is committed' [ -s "$TEST_ROOT/commits" ]
state_after_first="$(cat "$UCI_STATE")"
run_script
expect 'a second run changes nothing' [ "$state_after_first" = "$(cat "$UCI_STATE")" ]
echo 'ok - the advanced section is named, the persist interval dropped, and a rerun is a no-op'

reset_root
cat > "$UCI_STATE" <<-'EOF'
	ha-cluster.config=global
	ha-cluster.advanced=advanced
	ha-cluster.advanced.log_level='1'
	ha-cluster.@advanced[0]=advanced
	ha-cluster.@advanced[0].log_level='3'
EOF
run_script
expect 'a named advanced section is kept' grep -Fxq "ha-cluster.advanced.log_level='1'" "$UCI_STATE"
expect 'a second, anonymous one is not renamed over it' grep -Fxq "ha-cluster.@advanced[0].log_level='3'" "$UCI_STATE"
echo 'ok - a config with a named advanced section is not touched'

reset_root
rm -f "$CONFIG_DIR/ha-cluster"
printf '#!/bin/sh\n# guard of the previous image\n' > "$HOOKS/20-ipv6-backup-guard"
expect 'the script succeeds without a config' run_script
expect 'the handler is restored without a config' cmp -s "$GUARD" "$HOOKS/20-ipv6-backup-guard"
refute 'nothing is committed without a config' [ -e "$TEST_ROOT/commits" ]
expect 'the config is not created' [ ! -e "$CONFIG_DIR/ha-cluster" ]
echo 'ok - without a config only the handler is put back'

echo 'All ha-cluster upgrade script tests passed.'
