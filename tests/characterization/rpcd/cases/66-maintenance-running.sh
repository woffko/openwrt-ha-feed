# A maintenance command holds the lock while the status is asked:
# maintenance_running
mkdir -p /var/run/ha-cluster
( flock -x 9; sleep 20 ) 9>>/var/run/ha-cluster/maintenance.lock &
sleep 1
