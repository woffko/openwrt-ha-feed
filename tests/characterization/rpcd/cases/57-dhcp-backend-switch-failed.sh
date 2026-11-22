# A node on dnsmasq set to dhcp_backend 'kea' whose Kea does not start:
# DEGRADED, with why dnsmasq is still the server
. "$CHAR/backend/kea-switch.inc"
export FAKE_KEA_FAILS=1
uci set ha-cluster.config.dhcp_backend=kea
mkdir -p /etc/ha-cluster
echo dnsmasq > /etc/ha-cluster/dhcp-backend
