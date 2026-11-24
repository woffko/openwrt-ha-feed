# This node in maintenance until reboot: the state is MAINTENANCE, with the
# mode, when it began, and the last words of the command
mkdir -p /var/run/ha-cluster
echo "temp 1790000000" > /var/run/ha-cluster/maintenance
printf 'Started: maintenance temp\nMaintenance (temp) on\n' > /var/run/ha-cluster/maintenance.last
export FAKE_KEEPALIVED="$CHAR/rpcd/fixtures/keepalived-fault-init.json"
