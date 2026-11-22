# A config migrated at the first boot, as after every upgrade: the start
# finds nothing of the earlier model, logs nothing about it and does not
# write the config. With an anonymous advanced section next to the named
# one, which the migration leaves as it is (migration case 18), and
# sync_leases and sync_enabled where the migration does not look for them:
# not of the earlier model either, or every start would try again and fail.
uci add ha-cluster advanced >/dev/null
uci set ha-cluster.@advanced[-1].sync_interval='45'
uci set ha-cluster.config.sync_leases='1'
uci set ha-cluster.main.sync_enabled='1'

case_before_start() {
	md5sum /etc/config/ha-cluster > /tmp/char-config-md5
	ls -i /etc/config/ha-cluster > /tmp/char-config-inode
}

case_after() {
	echo "== config after start"
	md5sum -c /tmp/char-config-md5 >/dev/null 2>&1 && echo "same content" || echo "content changed"
	[ "$(ls -i /etc/config/ha-cluster)" = "$(cat /tmp/char-config-inode)" ] && echo "same file" || echo "file rewritten"
}
