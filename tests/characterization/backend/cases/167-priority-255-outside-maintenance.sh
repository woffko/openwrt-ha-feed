# priority 255 outside a maintenance (a config written before the views
# offered 1-254): keepalived would take the node for the owner of the
# addresses and ignore nopreempt and the weights of the checks, so the
# config has 254, with a warning
uci set ha-cluster.main.priority=255
case_after() {
	echo "== priorities: $(grep -E '^    priority ' "$KEEPALIVED_CONF" | tr -s ' ' | tr '\n' ',')"
}
