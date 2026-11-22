# dhcp_backend 'kea' with a kea-dhcp4 config that has no subnet for the
# address of 'lan': refused before anything is changed
. "$CHAR/backend/kea-switch.inc"
sed -i 's#192.168.50.0/24#10.9.9.0/24#' /etc/kea/kea-dhcp4.conf
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=kea; }
case_after() { kea_switch_after; }
