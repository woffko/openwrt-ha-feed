# No encryption key, owsync not installed: refused as well, lease-sync
# alone has work and needs the key
uci delete ha-cluster.config.encryption_key
rm -f /usr/bin/owsync /etc/init.d/owsync
