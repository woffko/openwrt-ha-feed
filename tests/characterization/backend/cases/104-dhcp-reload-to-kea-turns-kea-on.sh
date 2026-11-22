# A node on dnsmasq set to dhcp_backend 'kea' (LuCI's apply reloads): the
# HA cluster turns kea-dhcp4 on in /etc/config/kea, enables Kea's init
# script, imports, switches the pool off and restarts Kea
. "$CHAR/backend/kea-switch.inc"
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=kea; }
case_after() { kea_switch_after; }
