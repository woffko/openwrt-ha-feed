# Another switch holds the lock: nothing changes now and the status says
# why (the lock is asked for once a second, here for one second)
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1 HA_DHCP_BACKEND_LOCK_WAIT=1
case_before_start() {
	mkdir -p /var/lock
	exec 8>/var/lock/ha-cluster-dhcp-backend.lock
	flock -n -x 8
}
case_after() { kea_switch_after; }
