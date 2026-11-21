# A cluster that is switched off is stopped, whatever Kea reports
. "$CHAR/rpcd/kea-node.inc"
uci set ha-cluster.config.enabled=0
FAKE_RUNNING="kea-dhcp4"
export FAKE_KEA4_STATUS="$KEA_FIXTURES/kea-status-sockets-failed.json"
