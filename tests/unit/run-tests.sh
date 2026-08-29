#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

sh "$SCRIPT_DIR/test-dataplane-check.sh"
sh "$SCRIPT_DIR/test-ha-generator.sh"
