# dhcp_backend 'kea' on a node on dnsmasq, with a kea-dhcp4 config that does
# not listen on br-lan (its subnet still names br-lan, which makes Kea
# listen nowhere): refused before anything is changed
. "$CHAR/backend/kea-switch.inc"
sed -i 's/"br-lan" \]/"eth9" ]/' /etc/kea/kea-dhcp4.conf
STEP2=reload
step2() { uci set ha-cluster.config.dhcp_backend=kea; }
case_after() { kea_switch_after; }
