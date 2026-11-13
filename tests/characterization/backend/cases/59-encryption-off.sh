# sync_encryption '0' and no key: both daemons in plain mode, by choice
uci delete ha-cluster.config.encryption_key
uci set ha-cluster.config.sync_encryption=0
