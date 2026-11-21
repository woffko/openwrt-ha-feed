# firewall4 does not pass its check with the rules in place: they are taken
# out again and firewall4 is not reloaded with them
uci set ha-cluster.config.bind_address=172.30.0.10
export FAKE_FW4_CHECK_FAILS=1
