# The config of the releases before 2.0 at a start that cannot migrate it
# (the script is missing): an error in the log, and the cluster starts as
# it would have, with keepalived and without file or lease sync.
SKIP_MIGRATION=1
export HA_MIGRATE_CONFIG=/nonexistent/migrate-config
