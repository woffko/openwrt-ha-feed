# priority 255 (the address owner) and persistent maintenance at start:
# keepalived would ignore the demotion, so the config has 254
uci set ha-cluster.main.priority=255
uci set ha-cluster.config.maintenance=1
case_after() {
	echo "== priorities: $(grep -E '^    priority ' "$KEEPALIVED_CONF" | tr -s ' ' | tr '\n' ',')"
}
