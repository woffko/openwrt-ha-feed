# No key and no peer to sync with: no sync daemon has work, the key is
# not asked for and keepalived runs
uci delete ha-cluster.config.encryption_key
uci set ha-cluster.peer1.sync_enabled=0
