# A keepalived hook of the user's that brings the same interface up and
# down: the start warns that it should go
. "$CHAR/backend/uplinks.inc"
uplink_section wan wan master main
uci set network.wan.auto=0
case_before_start() {
	cat > /etc/hotplug.d/keepalived/900-pppoe <<'HOOK'
#!/bin/sh
WAN_MASTER_IFACES="wan"
[ "$ACTION" = MASTER ] && ifup wan || ifdown wan
HOOK
}
