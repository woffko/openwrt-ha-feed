# A change to /etc/config/dhcp that a user has staged in LuCI and not
# applied, when the node switches to Kea: the switch commits its own change
# (the pool switched off) and nothing of the user's, which stays staged
. "$CHAR/backend/kea-switch.inc"
uci set kea.dhcp4.disabled=0
export FAKE_KEA_ENABLED=1
case_before_start() {
	uci set dhcp.lan.leasetime=99h
}
case_after() {
	kea_switch_after
	echo "== staged by the user"
	uci changes dhcp
	echo "== leasetime in the config file: $(grep -c "99h" /etc/config/dhcp)"
}
