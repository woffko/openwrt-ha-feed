#!/bin/sh
# run-characterization-rootless.sh - T24 cases without a container runtime
#
# Runs the characterization cases of scenario 24 for hosts that have neither
# podman nor docker: each case runs in a bubblewrap sandbox over an unpacked
# OpenWrt rootfs with the HA packages installed, for example
# build_dir/target-*/root-* of an OpenWrt build or an unsquashed rootfs
# image. No root is needed. As in scenario 24, a case gets a throwaway
# system (here /etc, /tmp, /usr/bin, /usr/sbin and /usr/lib/ha-cluster; the
# rest is read-only) and no network, and its output is compared with
# tests/characterization/expected.
#
# From the working tree: what scenario 24 binds (the ha-cluster library,
# init script, shipped config and upgrade script, the rpcd handler and its
# ACL, dnsmasq's dhcp-script, lease-sync's hotplug script, init script and
# shipped config), plus this fork's dataplane checker and IPv6 BACKUP guard
# handler. Everything else, daemons and the other init scripts included, is
# the rootfs's.
#
# Usage: CHAR_ROOTFS=<rootfs dir> run-characterization-rootless.sh [<mode>...]
#   modes: backend rpcd acl migration hotplug lease-sync (default: all)
#   CHAR_UPDATE=1 rewrites the expected files instead of comparing.
#   CHAR_CASES=<pattern> runs only the cases whose name matches (shell glob).
#   CHAR_HIDE_INITD=<names> hides init scripts of the rootfs from the cases,
#     for services of packages the node image does not have (for example
#     keepalived-inotify, of keepalived-sync): the cases list /etc/rc.d.
#
# The rootfs is only read: rebuild it when the packages change, as for the
# node image of the container bench. /usr/bin and /usr/sbin are hard links
# to its files where the file system allows: a case may remove a file there,
# not change one in place.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
FEED_DIR="$(dirname "$TEST_DIR")"
CHAR_DIR="$TEST_DIR/characterization"
CHAR_UPDATE="${CHAR_UPDATE:-0}"
CHAR_CASES="${CHAR_CASES:-*}"
CHAR_HIDE_INITD="${CHAR_HIDE_INITD:-}"
ROOTFS="${CHAR_ROOTFS:-}"

die() {
	echo "$*" >&2
	exit 2
}

[ -n "$ROOTFS" ] || die "CHAR_ROOTFS is not set (an unpacked OpenWrt rootfs with the HA packages)"
[ -x "$ROOTFS/sbin/uci" ] || die "$ROOTFS: no sbin/uci, not an OpenWrt rootfs"
[ -f "$ROOTFS/usr/lib/ha-cluster/ha-cluster.sh" ] || die "$ROOTFS: ha-cluster is not installed"
command -v bwrap >/dev/null 2>&1 || die "bwrap (bubblewrap) not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found (needed to format rpcd JSON)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# Usage: run_case <mode> <case file name>
run_case() {
	local mode="$1"
	local case_name="$2"
	local entry

	rm -rf "$WORK/etc" "$WORK/tmp" "$WORK/usr-bin" "$WORK/usr-sbin" "$WORK/ha-lib"
	cp -a "$ROOTFS/etc" "$WORK/etc"
	# What the package installs besides the files bound below
	cp -a "$ROOTFS/usr/lib/ha-cluster" "$WORK/ha-lib"
	cp "$FEED_DIR/ha-cluster/files/check-dataplane.sh" "$WORK/ha-lib/check-dataplane"
	cp "$FEED_DIR/ha-cluster/files/ipv6-backup-guard.hotplug" "$WORK/ha-lib/ipv6-backup-guard"
	cp "$FEED_DIR/ha-cluster/files/ha-cluster.uci-defaults" "$WORK/ha-lib/migrate-config"
	mkdir -p "$WORK/etc/hotplug.d/keepalived"
	cp "$FEED_DIR/ha-cluster/files/ipv6-backup-guard.hotplug" "$WORK/etc/hotplug.d/keepalived/20-ipv6-backup-guard"
	chmod 0755 "$WORK/ha-lib/check-dataplane" "$WORK/ha-lib/ipv6-backup-guard" \
		"$WORK/etc/hotplug.d/keepalived/20-ipv6-backup-guard"
	mkdir -p "$WORK/tmp/run" "$WORK/tmp/lock"
	for entry in $CHAR_HIDE_INITD; do
		rm -f "$WORK/etc/init.d/$entry" "$WORK/etc/rc.d/"[SK][0-9][0-9]"$entry"
	done
	# Cases remove daemons from these two: a tree of hard links, where a
	# removal leaves the rootfs alone, or a copy across file systems
	for entry in bin sbin; do
		cp -al "$ROOTFS/usr/$entry" "$WORK/usr-$entry" 2>/dev/null ||
			cp -a "$ROOTFS/usr/$entry" "$WORK/usr-$entry"
	done
	# Kea, luci-app-kea and kea-dnsmasq-hosts are not installed for the
	# cases, whatever the rootfs holds (the node image has them since
	# w0w6): a case about Kea puts its own stand-ins in place
	rm -rf "$WORK/usr-sbin/"kea-* "$WORK/etc/kea" "$WORK/etc/config/kea" \
		"$WORK/etc/config/kea-dnsmasq-hosts" "$WORK/etc/init.d/kea" \
		"$WORK/etc/init.d/kea-dnsmasq-hosts" "$WORK/etc/rc.d/"[SK][0-9][0-9]kea \
		"$WORK/etc/rc.d/"[SK][0-9][0-9]kea-dnsmasq-hosts

	# Top-level directories of the rootfs read-only; /etc, /tmp, /usr/bin
	# and /usr/sbin writable and thrown away after the case
	set -- --unshare-all --die-with-parent --uid 0 --gid 0 --hostname ha-char \
		--tmpfs / --proc /proc --dev /dev
	for entry in "$ROOTFS"/*; do
		case "$(basename "$entry")" in
			etc|tmp|var|proc|dev|sys) continue ;;
		esac
		if [ -L "$entry" ]; then
			set -- "$@" --symlink "$(readlink "$entry")" "/$(basename "$entry")"
		elif [ -d "$entry" ]; then
			set -- "$@" --ro-bind "$entry" "/$(basename "$entry")"
		fi
	done

	[ -d "$ROOTFS/usr/libexec/luci-app-kea" ] &&
		set -- "$@" --tmpfs /usr/libexec/luci-app-kea
	[ -d "$ROOTFS/usr/share/kea" ] &&
		set -- "$@" --tmpfs /usr/share/kea
	[ -d "$ROOTFS/usr/lib/kea" ] &&
		set -- "$@" --tmpfs /usr/lib/kea

	timeout 300 bwrap "$@" \
		--bind "$WORK/etc" /etc \
		--bind "$WORK/tmp" /tmp \
		--bind "$WORK/usr-bin" /usr/bin \
		--bind "$WORK/usr-sbin" /usr/sbin \
		--bind "$WORK/ha-lib" /usr/lib/ha-cluster \
		--symlink tmp /var \
		--ro-bind "$FEED_DIR/ha-cluster/files/ha-cluster.sh" /usr/lib/ha-cluster/ha-cluster.sh \
		--ro-bind "$FEED_DIR/ha-cluster/files/ha-cluster.init" /etc/init.d/ha-cluster \
		--ro-bind "$FEED_DIR/ha-cluster/files/ha-cluster.config" /shipped/ha-cluster \
		--ro-bind "$FEED_DIR/ha-cluster/files/ha-cluster.uci-defaults" /char-migrate \
		--ro-bind "$FEED_DIR/luci-app-ha-cluster/root/usr/libexec/rpcd/ha-cluster" /usr/libexec/rpcd/ha-cluster \
		--ro-bind "$FEED_DIR/luci-app-ha-cluster/root/usr/share/rpcd/acl.d/luci-app-ha-cluster.json" /usr/share/rpcd/acl.d/luci-app-ha-cluster.json \
		--ro-bind "$FEED_DIR/dnsmasq-ha/files/dhcp-script.sh" /char-dhcp-script \
		--ro-bind "$FEED_DIR/lease-sync/files/lease-sync.hotplug" /char-lease-sync-hotplug \
		--ro-bind "$FEED_DIR/lease-sync/files/lease-sync.init" /char-lease-sync-init \
		--ro-bind "$FEED_DIR/lease-sync/files/lease-sync.config" /shipped/lease-sync \
		--ro-bind "$CHAR_DIR" /char \
		/bin/sh /char/harness.sh "$mode" "/char/$mode/cases/$case_name"
}

# Pretty-print the rpcd JSON (last line) so that diffs are per field
format_output() {
	if [ "$1" = "rpcd" ]; then
		sed '$d' "$2"
		tail -n 1 "$2" | python3 -m json.tool
	else
		cat "$2"
	fi
}

total=0
failed=0
updated=0

[ "$#" -gt 0 ] || set -- backend rpcd acl migration hotplug lease-sync

for mode in "$@"; do
	[ -d "$CHAR_DIR/$mode/cases" ] || die "unknown mode: $mode"

	for case_file in "$CHAR_DIR/$mode/cases/"*.sh; do
		case_name="$(basename "$case_file" .sh)"
		# shellcheck disable=SC2254
		case "$case_name" in
			$CHAR_CASES) ;;
			*) continue ;;
		esac
		expected="$CHAR_DIR/expected/$mode/$case_name.out"
		total=$((total + 1))

		if ! run_case "$mode" "$case_name.sh" > "$WORK/raw" 2> "$WORK/errors"; then
			echo "FAIL $mode/$case_name: case run failed"
			cat "$WORK/raw" "$WORK/errors"
			failed=$((failed + 1))
			continue
		fi
		[ -s "$WORK/errors" ] && echo "WARN $mode/$case_name: $(cat "$WORK/errors")"
		if ! format_output "$mode" "$WORK/raw" > "$WORK/actual"; then
			echo "FAIL $mode/$case_name: output cannot be formatted"
			cat "$WORK/raw"
			failed=$((failed + 1))
			continue
		fi

		if [ "$CHAR_UPDATE" = "1" ]; then
			if ! cmp -s "$WORK/actual" "$expected"; then
				mkdir -p "$(dirname "$expected")"
				cp "$WORK/actual" "$expected"
				echo "UPDATED $mode/$case_name"
				updated=$((updated + 1))
			fi
		elif [ ! -f "$expected" ]; then
			echo "FAIL $mode/$case_name: no expected output (run with CHAR_UPDATE=1)"
			failed=$((failed + 1))
		elif ! cmp -s "$WORK/actual" "$expected"; then
			echo "FAIL $mode/$case_name: output differs from $expected"
			diff -u "$expected" "$WORK/actual" | sed -n '1,40p'
			failed=$((failed + 1))
		fi
	done
done

if [ "$CHAR_UPDATE" = "1" ]; then
	echo "characterization: $total cases, $updated expected files rewritten, $failed failed"
else
	echo "characterization: $total cases, $failed failed"
fi
[ "$failed" -eq 0 ]
