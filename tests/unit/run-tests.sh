#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

sh "$SCRIPT_DIR/test-dataplane-check.sh"
sh "$SCRIPT_DIR/test-ha-generator.sh"
sh "$SCRIPT_DIR/test-ha-guard-on-stop.sh"
sh "$SCRIPT_DIR/test-ha-sync-gating.sh"
sh "$SCRIPT_DIR/test-ha-upgrade-defaults.sh"
sh "$SCRIPT_DIR/test-ipv6-backup-guard.sh"
sh "$SCRIPT_DIR/test-kea-dnsmasq-hosts.sh"
sh "$SCRIPT_DIR/test-ha-run-dir.sh"
sh "$SCRIPT_DIR/test-owsync-changed.sh"
