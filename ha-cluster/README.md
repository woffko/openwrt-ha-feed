# ha-cluster - High Availability for OpenWrt

Meta-package that orchestrates keepalived (VRRP), owsync (config sync), and
lease-sync (DHCP lease sync) to provide seamless failover between OpenWrt
routers.

## Installation

### Automated (recommended)

Copy the installation script to your router and run it:

```sh
scp scripts/install-ha-cluster.sh root@router:/tmp/
ssh root@router sh /tmp/install-ha-cluster.sh
```

The script handles the dnsmasq-to-dnsmasq-ha swap safely by pre-installing
dependencies and pre-downloading packages while DNS is still available.

### Manual

If you prefer to install manually, or if the script fails:

```sh
# 1. Update package lists
apk update

# 2. Pre-install ALL dependencies from official feeds (while DNS works)
apk add libnettle kmod-ipt-ipset libnetfilter-conntrack nftables-json
apk add keepalived
apk add libopenssl3

# 3. Swap dnsmasq for dnsmasq-ha and install remaining packages
apk del dnsmasq              # or: apk del dnsmasq-full
apk add dnsmasq-ha ha-cluster owsync lease-sync luci-app-ha-cluster
```

**Why the explicit swap?** dnsmasq-ha replaces stock dnsmasq. Removing
dnsmasq kills DNS resolution, so ALL dependencies must be pre-installed
before the swap.

## Dependencies

- `keepalived` - VRRP failover
- `owsync` - Bidirectional config file synchronization
- `lease-sync` - Real-time DHCP lease replication via dnsmasq ubus
- `dnsmasq-ha` - dnsmasq with ubus lease methods

Optional: `luci-app-ha-cluster` for web interface.

## How It Works

ha-cluster reads `/etc/config/ha-cluster` and generates flat config files
for each service under `/tmp/ha-cluster/`:

```
/etc/config/ha-cluster  →  /tmp/ha-cluster/keepalived.conf
                        →  /tmp/ha-cluster/owsync.conf
                        →  /tmp/ha-cluster/lease-sync.conf
```

All three daemons are started as procd instances by ha-cluster. Do **not**
use standalone init scripts (`/etc/init.d/keepalived`, `/etc/init.d/owsync`,
`/etc/init.d/lease-sync`) while ha-cluster is enabled — they generate their
own configs and would conflict.

Any `uci commit ha-cluster` automatically triggers a service reload.

## Quick Start

```sh
# Generate an encryption key
KEY=$(hexdump -n 32 -v -e '1/1 "%02x"' /dev/urandom)

# Minimal configuration
uci set ha-cluster.config.enabled='1'
uci set ha-cluster.config.node_priority='100'
uci set ha-cluster.config.encryption_key="$KEY"

# Add a peer
uci add ha-cluster peer
uci set ha-cluster.@peer[-1].name='router2'
uci set ha-cluster.@peer[-1].address='192.168.1.2'

# Create a VRRP instance (all VIPs in same instance fail over together)
uci set ha-cluster.main=vrrp_instance
uci set ha-cluster.main.vrid='51'
uci set ha-cluster.main.interface='lan'
uci set ha-cluster.main.priority='100'
uci set ha-cluster.main.nopreempt='1'

# Configure a VIP
uci set ha-cluster.lan=vip
uci set ha-cluster.lan.enabled='1'
uci set ha-cluster.lan.vrrp_instance='main'
uci set ha-cluster.lan.interface='br-lan'
uci set ha-cluster.lan.address='192.168.1.254'
uci set ha-cluster.lan.netmask='255.255.255.0'

# Apply
uci commit ha-cluster
```

Repeat on each peer node with the appropriate priority and peer addresses.

## DHCP Prerequisites

When using lease sync (`sync_leases='1'`), each VIP interface must have
`force=1` in its DHCP configuration:

```sh
uci set dhcp.lan.force='1'
uci commit dhcp
```

**Why?** Without `force=1`, dnsmasq detects the peer's DHCP server on the
same network and disables its own DHCP service on that interface. This
prevents the ubus `add_lease` method from working — lease-sync cannot
inject leases into a node whose DHCP subsystem is not initialized. DNS
resolution for local hostnames would fail on the BACKUP node.

ha-cluster validates this at startup and refuses to start if `force=1` is
missing on any VIP interface with lease sync enabled.

Only set `force=1` on interfaces where you need HA DHCP. Other interfaces
(management networks, etc.) retain normal dhcp_check protection.

## UCI Configuration

All configuration lives in `/etc/config/ha-cluster`.

### Global settings (`config global 'config'`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `0` | Enable/disable ha-cluster |
| `node_priority` | int | `100` | VRRP priority (1-255, higher wins MASTER) |
| `vrrp_transport` | string | `multicast` | VRRP transport: `multicast` or `unicast`. When `unicast`, auto-derives addresses from peer config |
| `sync_method` | string | `owsync` | Sync backend: `owsync` or `none` |
| `sync_encryption` | bool | `1` | Encrypt owsync traffic (AES-256-GCM) |
| `encryption_key` | string | | 256-bit hex key (use LuCI "Generate" button or `hexdump -n 32 -v -e '1/1 "%02x"' /dev/urandom`) |
| `sync_port` | int | `4321` | owsync TCP port |
| `sync_dir` | string | `/etc/config` | Directory to synchronize |
| `bind_address` | string | | Local IP for sync traffic (use real IP, not VIP) |

### VRRP Instances (`config vrrp_instance '<name>'`)

Each section defines a VRRP instance. All VIPs referencing the same instance
fail over atomically as a group (one advertisement, one failover event).

When any VIP in the group has `address6` set, a second VRRP instance is
created automatically using VRID+128 for all IPv6 VIPs.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `vrid` | int | | VRRP router ID (1-127, 128+ reserved for IPv6) |
| `interface` | string | | Primary interface for VRRP advertisements |
| `priority` | int | | Override global `node_priority` for this instance |
| `nopreempt` | bool | `1` | Don't reclaim MASTER on recovery |
| `preempt_delay` | int | | Delay before preempting (seconds) |
| `garp_master_delay` | int | | Gratuitous ARP delay after becoming MASTER |
| `advert_int` | int | `1` | VRRP advertisement interval (seconds) |
| `track_interface` | list | | Interfaces to track for failover |
| `track_script` | list | | Health check script names |
| `auth_type` | string | `none` | VRRP auth: `none`, `pass`, or `ah` |
| `auth_pass` | string | | VRRP auth password |
| `unicast_src_ip` | string | | Source IP for unicast VRRP (overrides auto-derivation) |
| `unicast_peer` | list | | Unicast peer IPs (overrides auto-derivation) |

### Virtual IPs (`config vip '<name>'`)

Each VIP references a `vrrp_instance` section. Multiple VIPs can share the
same instance for atomic failover.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `1` | Enable this VIP |
| `vrrp_instance` | string | | Name of `vrrp_instance` section |
| `interface` | string | | Network interface for this VIP (e.g. `br-lan`) |
| `address` | string | | Virtual IPv4 address |
| `netmask` | string | `255.255.255.0` | IPv4 netmask |
| `address6` | string | | Virtual IPv6 address (optional, uses VRID+128) |
| `prefix6` | int | `64` | IPv6 prefix length |

### Peers (`config peer`)

| Option | Type | Description |
|--------|------|-------------|
| `name` | string | Peer identifier |
| `address` | string | Peer IP address |
| `source_address` | string | Local IP to use when contacting this peer (also used as `unicast_src_ip` for auto-derivation) |
| `sync_enabled` | bool | `1` | Enable owsync/lease-sync for this peer. Set to `0` for non-OpenWrt peers (VRRP-only) |

### Services (`config service '<name>'`)

Each service section defines a sync group for owsync.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `0` | Enable sync for this group |
| `config_files` | list | | UCI config names or paths to sync |
| `sync_leases` | bool | `0` | Enable lease-sync daemon (dhcp service only) |

### Exclusions (`config exclude`)

| Option | Type | Description |
|--------|------|-------------|
| `file` | list | UCI config names to never sync |

Default exclusions: `network`, `system`, `owsync`, `ha-cluster`, `wireless`.

### Health check scripts (`config script '<name>'`)

Command checks remain compatible with explicit `track_script` lists. Setting
`vrrp_instance` makes a check package-managed: ha-cluster attaches it to every
selected IPv4 instance and to each generated IPv6 instance automatically. A
legacy scalar `option vrrp_instance` remains supported; use repeated
`list vrrp_instance` entries when related gateway groups must move together.

The `dataplane` check type runs `/usr/lib/ha-cluster/check-dataplane`. It checks
the selected device carrier, optionally checks the active 802.3ad member count,
and sends interface-bound probes to literal IP targets. A target assigned to
the local node is skipped, so peers may use mirrored target lists. With
`min_success='1'`, the check fails only when every eligible target is
unreachable.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `check_type` | string | `command` | `command` or package-managed `dataplane` |
| `vrrp_instance` | list | | Automatically attach the check to these VRRP groups; at least one is required for `dataplane` |
| `script` | string | | Absolute command for `command` checks |
| `interface` | string | | Linux device used by a `dataplane` check (for example `bond0.87`) |
| `bond` | string | | Optional parent 802.3ad bond device |
| `target` | list | | Literal IPv4/IPv6 probe targets |
| `min_success` | int | `1` | Required successful non-local targets |
| `min_lacp_members` | int | `0` | Required active LACP members; `0` disables this check |
| `probe_timeout` | int | `1` | Per-target ping timeout in seconds |
| `interval` | int | `5` | Check interval (seconds) |
| `timeout` | int | | Complete script timeout; allow for every target probe to time out |
| `weight` | int | | Empty/`0` causes FAULT; a non-zero value adjusts priority only |
| `rise` | int | | Successes before marking UP (keepalived default applies) |
| `fall` | int | | Failures before marking DOWN (keepalived default applies) |
| `user` | string | | User to run script as |

Example:

```uci
config script 'check_lan_dataplane'
	option check_type 'dataplane'
	list vrrp_instance 'lan'
	list vrrp_instance 'guest'
	option interface 'bond0.20'
	option bond 'bond0'
	option min_lacp_members '1'
	list target '192.168.20.10'
	list target '192.168.20.11'
	option min_success '1'
	option probe_timeout '1'
	option interval '2'
	option timeout '3'
	option weight '0'
	option rise '5'
	option fall '3'
```

### Advanced settings (`config advanced`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `log_level` | int | `2` | 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG |
| `owsync_log_level` | int | `2` | owsync log level |
| `sync_interval` | int | `30` | owsync poll interval (seconds) |
| `lease_sync_port` | int | `5378` | lease-sync UDP port |
| `lease_sync_interval` | int | `30` | lease-sync periodic sync (seconds) |
| `lease_sync_peer_timeout` | int | `120` | Peer timeout (seconds) |
| `lease_sync_persist_interval` | int | `60` | Persist interval (seconds) |
| `lease_sync_log_level` | int | `2` | lease-sync log level |
| `max_auto_priority` | int | `0` | Auto-priority cap (0 = disabled) |
| `enable_notifications` | bool | `0` | Email notifications |
| `notification_email` | list | | Notification recipients |
| `notification_email_from` | string | | Sender address for notifications |
| `smtp_server` | string | | SMTP server address |

## State Change Hooks

keepalived state transitions trigger the OpenWrt hotplug system.
Custom scripts can be placed in `/etc/hotplug.d/keepalived/` with a
numeric prefix above 50 (e.g. `60-vpn-failover`).

Available environment variables:
- `ACTION` — `MASTER`, `BACKUP`, `FAULT`, or `STOP`
- `TYPE` — `INSTANCE`, `GROUP`, etc.
- `NAME` — instance name (e.g. `main`)

## Files

```
/etc/config/ha-cluster                  UCI configuration
/etc/init.d/ha-cluster                  procd init script (START=19, STOP=91)
/usr/lib/ha-cluster/ha-cluster.sh       Core library
/tmp/ha-cluster/                        Generated configs (runtime)
```

## License

MIT. See LICENSE file.

ha-cluster has been developed using Claude Code from Anthropic.

## Maintainer

Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
