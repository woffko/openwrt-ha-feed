# No encryption key: refused. The fork encrypts unless sync_encryption is
# '0' (backend/59), and never falls back to plain mode
uci delete ha-cluster.config.encryption_key
