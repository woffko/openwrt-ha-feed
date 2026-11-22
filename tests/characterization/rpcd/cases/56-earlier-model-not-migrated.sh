# The config of the releases before 2.0, which the start could not migrate:
# the daemons run and the peer answers, but nothing is synced. DEGRADED,
# with what the config holds of the earlier model.
SKIP_MIGRATION=1
export HA_MIGRATE_CONFIG=/nonexistent/migrate-config
