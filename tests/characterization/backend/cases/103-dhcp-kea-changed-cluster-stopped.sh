# luci-app-kea's event while the cluster is stopped: the command notes
# whether Kea was stopped on purpose and starts nothing
. "$CHAR/backend/kea-switch.inc"
STEP2=kea_changed
step2() { procd_kill ha-cluster; }
case_after() { kea_switch_after; }
