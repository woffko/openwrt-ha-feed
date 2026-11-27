# LuCI Application for HA Cluster

Web interface for managing High Availability clusters on OpenWrt.

## Features

### General Tab
- Simple multi-router HA configuration (2 or more nodes)
- Priority configuration
- Peer router management
- VRRP instance management (VIPs grouped by instance fail over atomically)
- Virtual IP (VIP) configuration per interface with instance selector
- Inline VRRP instance creation from VIP modal ("Add new..." option)
- Service synchronization selection
- One-click enable/disable

### Status Tab
- Real-time cluster state (MASTER/BACKUP/FAULT) and the role of each VRRP instance
- Peer connectivity status
- Service health monitoring (keepalived, owsync, lease-sync, Kea)
- The DHCP server of the cluster interfaces (dnsmasq or Kea), the state of Kea's high availability, and the static leases of dnsmasq not yet in Kea
- The uplinks that follow the role: what each should be, what it is, and why not
- Maintenance: enter it until reboot or persistently, leave it, see the result of the last command and whether the peer is in maintenance
- DHCP lease sync statistics
- Config sync statistics
- Auto-refresh every 5 seconds

### Advanced Pages
- **Advanced VRRP**: VRRP tuning, GUI-managed command or dataplane health checks with automatic multi-instance IPv4/IPv6 attachment, and the custom hooks of `/etc/hotplug.d/keepalived/`
- **Advanced Multi-WAN Management**: every WAN interface (those of mwan3 and of the masquerading firewall zones), listed as unmanaged until it is given a mode: `Master only` for a line that allows one session, such as PPPoE, or `Always`
- **Advanced Config Sync**: Custom sync groups, exclusions, poll interval
- **Advanced Lease Sync**: lease-sync tuning and logging

What these pages configure is described in
[ha-cluster's README](../ha-cluster/README.md).

## Installation

From your own package repository (see
[Building and Hosting Your Own Package Repository](../README.md#building-and-hosting-your-own-package-repository)):

```bash
apk update
apk add luci-app-ha-cluster
```

Install or upgrade it together with `ha-cluster`: each release of the
interface goes with one release of the backend.

## Dependencies

- `ha-cluster` - HA cluster management package
- `luci-base` - LuCI base system
- `rpcd` - RPC daemon

## Files

```
/www/luci-static/resources/
└── view/ha-cluster/
    ├── simple.js              # General interface
    ├── status.js              # Status dashboard
    ├── keepalived-advanced.js # Advanced VRRP settings
    ├── uplinks.js             # Advanced Multi-WAN Management
    ├── owsync-advanced.js     # Advanced config sync settings
    └── lease-sync-advanced.js # Advanced DHCP sync settings

/usr/share/luci/menu.d/
└── luci-app-ha-cluster.json   # Menu definition

/usr/share/rpcd/acl.d/
└── luci-app-ha-cluster.json   # Access control

/usr/libexec/rpcd/
└── ha-cluster                 # RPC backend (shell script)
```

## Access Control

The ACL has two roles. `read` calls `status`, `nodes` and `generate_key`
and reads the `ha-cluster`, `dhcp`, `network`, `firewall` and `mwan3`
configs. `write` changes the `ha-cluster` config, the hooks of
`/etc/hotplug.d/keepalived/` and calls `maintenance`. Health checks of
type `command` and those hooks run as root, and the `ha-cluster` config
holds the encryption key: give either role only to users who may be root
on the router.

## Usage

1. Navigate to **Services → High Availability** in LuCI
2. Go to **General** tab
3. Configure:
   - Enable HA Cluster
   - Set priority
   - Add peer router IP
   - Configure Virtual IPs for each interface
   - Select services to synchronize
4. Save & Apply

## Screenshots

### General
Simple form-based configuration for typical multi-router setups:
- Cluster settings (priority, VRRP transport)
- Peer configuration
- Virtual IP addresses
- Service sync options

### Status Dashboard
Real-time monitoring with:
- Cluster state indicator (color-coded)
- Peer health status
- Service status table
- Uplinks and maintenance
- Sync statistics

## Development

### Testing Locally

```bash
# Build the package
make package/luci-app-ha-cluster/compile

# Install on router
scp bin/packages/*/luci/luci-app-ha-cluster_*.apk root@router:/tmp/
ssh root@router apk add /tmp/luci-app-ha-cluster_*.apk

# Clear LuCI cache
ssh root@router rm -rf /tmp/luci-*
```

### Debugging

Enable debug mode in browser console:
```javascript
L.env.sessionid
```

Check RPC calls:
```bash
ubus call ha-cluster status
```

View logs:
```bash
logread | grep luci
logread | grep ha-cluster
```

## License

Apache-2.0

luci-app-ha-cluster has been developed using Claude Code from Anthropic.

## Maintainer

Upstream: Pierre Gaufillet <pierre.gaufillet@bergamote.eu>

This fork: [woffko](https://github.com/woffko)
