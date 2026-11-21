# No firewall config (firewall4 not installed): nothing is written and
# nothing is said
uci set ha-cluster.config.bind_address=172.30.0.10
rm -f /etc/config/firewall
