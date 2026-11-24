# Two uplinks on a MASTER: the PPPoE wan (master) has been down for 400 s,
# longer than its grace, after an authentication failure: the cluster is
# DEGRADED. The static wanb (always) is up.
. "$CHAR/backend/uplinks.inc"
uci set network.wan.auto=0
uplink_section wan wan master main
uplink_section wanb wanb always
mkdir -p /var/run/ha-cluster/role
echo "MASTER 500" > /var/run/ha-cluster/role/instance.main
echo "up 500 500 0 600" > /var/run/ha-cluster/role/uplink.wan
echo "up 0 0 0 0" > /var/run/ha-cluster/role/uplink.wanb
ifstatus_fixture wan false false false AUTH_TOPEER_FAILED
echo '{ "up": true, "pending": false, "autostart": true, "uptime": 3600 }' > /tmp/ifstatus/wanb.json
