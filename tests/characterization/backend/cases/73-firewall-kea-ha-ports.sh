# Kea as the DHCP server, both Kea daemons enabled: the ports of the "url"s
# in their configs are opened for the nodes that sync, each once, and a url
# in a comment is not one. No rule for lease-sync, which does not run
uci set ha-cluster.config.dhcp_backend=kea
uci set ha-cluster.config.bind_address=172.30.0.10
uci delete dhcp.lan.force
: > /etc/config/kea
uci set kea.dhcp4=service
uci set kea.dhcp4.disabled=0
uci set kea.dhcp6=service
uci set kea.dhcp6.disabled=0
mkdir -p /etc/kea
cat > /etc/kea/kea-dhcp4.conf <<'KEA'
{ "Dhcp4": { "interfaces-config": { "interfaces": [ "br-lan" ], "service-sockets-max-retries": 60 },
  "hooks-libraries": [ { "library": "/usr/lib/kea/hooks/libdhcp_ha.so", "parameters": { "high-availability": [ {
    "this-server-name": "ha-172-30-0-10", "mode": "hot-standby",
    // "url": "http://172.30.0.10:9999/",
    "peers": [ { "name": "ha-172-30-0-10", "url": "http://172.30.0.10:8001/", "role": "primary" }, { "name": "ha-172-30-0-11", "url": "http://172.30.0.11:8001/", "role": "standby" } ] } ] } } ] } }
KEA
cat > /etc/kea/kea-dhcp6.conf <<'KEA'
{ "Dhcp6": { "interfaces-config": { "interfaces": [ "br-lan" ], "service-sockets-max-retries": 60 },
  "hooks-libraries": [ { "library": "/usr/lib/kea/hooks/libdhcp_ha.so", "parameters": { "high-availability": [ {
    "peers": [
      { "name": "ha-172-30-0-10", "url": "http://172.30.0.10:8002/", "role": "primary" },
      { "name": "ha-172-30-0-11", "url": "http://[fd00:172:30::11]:8002/", "role": "standby" } ] } ] } } ] } }
KEA
