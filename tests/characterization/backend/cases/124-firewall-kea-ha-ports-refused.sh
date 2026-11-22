# Kea as the DHCP server with "url" ports that the rule of Kea's high
# availability does not open: 22, below 1024, and 4321, the port of owsync.
# Only 8001 is opened, and the other two are warned about at start
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
      { "name": "ha-172-30-0-10", "url": "http://172.30.0.10:22/", "role": "primary" },
      { "name": "ha-172-30-0-11", "url": "http://[fd00:172:30::11]:4321/", "role": "standby" } ] } ] } } ] } }
KEA
