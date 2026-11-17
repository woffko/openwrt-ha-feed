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
apk add libnettle libnetfilter-conntrack nftables-json
apk add keepalived
apk add libopenssl3

# 3. Download the feed packages (while DNS works)
mkdir -p /tmp/ha-pkgs && cd /tmp/ha-pkgs
apk fetch dnsmasq-ha ha-cluster owsync lease-sync luci-app-ha-cluster

# 4. Swap dnsmasq for dnsmasq-ha, then install the rest, from local files
apk del dnsmasq              # or: apk del dnsmasq-full
apk add --allow-untrusted /tmp/ha-pkgs/dnsmasq-ha-*.apk
apk add --allow-untrusted /tmp/ha-pkgs/*.apk
```

**Why the explicit swap?** dnsmasq-ha replaces stock dnsmasq. Removing
dnsmasq kills DNS resolution, so ALL dependencies must be pre-installed
and the feed packages downloaded before the swap. Feed packages are signed
through the repository index, not individually, so a local file needs
`--allow-untrusted`.

## Upgrading

Upgrading from 1.0.x to 2.0.0 migrates `/etc/config/ha-cluster` in place
before ha-cluster regenerates its configuration:

- `service` sections become `sync_group` sections
- the `dhcp` group's `sync_leases` becomes the global `lease_sync`, and
  `sync_leases` is removed from every group
- a `sync_method` other than `owsync` disables every sync group and is
  removed
- peer `sync_enabled '0'` becomes `vrrp_only '1'`
- an unnamed `config advanced` section, as shipped in 1.0.x, is named
  `advanced` so that its settings are read: only the first one if
  several, and none if a section is already named `advanced`
- `lease_sync_persist_interval` is removed

The migration expects VRRP settings in `vrrp_instance` sections. A
config from the `v1.0.0` feed tag, where each `vip` carries its own
`vrid` and `priority`, is not converted and gets no VRRP instance:
recreate its VIPs (for example in LuCI) after upgrading.

apk installs the new default config next to an edited one as
`/etc/config/ha-cluster.apk-new`: it is for reference only, the migrated
file stays in use.

The upgrade restarts keepalived once (its procd instance parameters
change): upgrade the BACKUP nodes first, so that upgrading the MASTER
causes a single switchover.

Behaviour changes:

- A `vip` without an `enabled` option is now enabled, as LuCI shows it;
  1.0.x skipped it. It is also validated like the other VIPs (a failed
  check, such as a missing `force` on its DHCP interface, stops
  ha-cluster): set `enabled '0'` before upgrading to keep it off.
- lease-sync follows `lease_sync` alone: a disabled `dhcp` sync group no
  longer stops it. Set `lease_sync '0'` to keep it off.
- owsync no longer runs without work (see
  [Which daemons run](#which-daemons-run)).
- With unicast peers, a VRRP instance whose peers and VIPs are all IPv6
  now runs as `<name>` with its VRID, no longer as `<name>_v6` with
  VRID+128. Nodes on different versions do not see each other for that
  instance: upgrade all nodes together, and update hotplug scripts
  matching `<name>_v6`.
- With IPv6 unicast peers and only IPv4 VIPs, the instance now
  advertises no address (`no_virtual_ipaddress`, VIPs in
  `virtual_ipaddress_excluded`): a `vrrp_only` peer that is not
  keepalived may not accept it.
- An authoritative dnsmasq now draws a warning when leases or the DHCP
  config are synced (see [DHCP Prerequisites](#dhcp-prerequisites)).

The upgrade starts `/etc/init.d/ha-cluster` even if it was disabled with
`/etc/init.d/ha-cluster disable` (standard OpenWrt packaging). The
switch that the upgrade respects is ha-cluster's own `enabled` option.

### Notes for this fork

They add to the list above when a node runs this fork's packages.

- **Encryption key.** As soon as a sync daemon has work (see
  [Which daemons run](#which-daemons-run)), ha-cluster does not start
  without a valid `encryption_key` (64 hexadecimal characters), keepalived
  included. Set the same key on every node before upgrading, or
  `sync_encryption '0'` to sync in plaintext on purpose.
- **`sync_method 'none'`.** The migration turns it into `enabled '0'` on
  every sync group and removes the option. Lease sync follows
  `lease_sync` alone, as before.
- **Authoritative DHCP.** Earlier releases of this fork made dnsmasq
  authoritative through the overlay they wrote. The overlay no longer
  does, and `/etc/config/dhcp` decides: set `authoritative '0'` on every
  node (`uci set dhcp.@dnsmasq[0].authoritative='0'; uci commit dhcp`),
  as [DHCP Prerequisites](#dhcp-prerequisites) explains. Until then
  ha-cluster logs a warning.
- **IPv6 BACKUP guard.** For each section with an IPv6 VIP, a node that is
  not MASTER drops its outgoing Router Advertisements and the incoming
  DHCPv6 requests on the section's interface, so that clients neither
  route through it nor get addresses from it. The state that counts is
  that of `<name>_v6` with multicast VRRP and of `<name>` with unicast
  VRRP; the guard is rebuilt after every start and reload. Custom hooks
  in `/etc/hotplug.d/keepalived/` that match `<name>_v6` need the same
  distinction for unicast instances.
- **Stopping a node.** `/etc/init.d/ha-cluster stop` leaves the guard
  closed on every section: the node's dnsmasq goes on running without HA
  and would otherwise advertise the node as a router and hand out DHCPv6
  addresses. The guard opens again when the service starts and the node
  becomes MASTER. A node taken out of the cluster gets the rules removed:
  set `enabled '0'` in the `config` section and apply, or disable the
  service (`/etc/init.d/ha-cluster disable`) before stopping it. Removing
  the package does the latter.
- **Router Advertisements of the MASTER.** The guard lets a MASTER send
  Router Advertisements from one source address only, the virtual
  link-local address of the section: option `virtual_link_local` of the
  `vrrp_instance` section, else a link-local `address6` of one of its
  VIPs, else `fe80::5`. Advertisements from any other source address are
  dropped, so a section without that address on its interface advertises
  nothing: give it a link-local VIP.
- **Advanced section.** Settings in an unnamed `config advanced` section
  were ignored by the 1.0.x backend and take effect once the section is
  named: check that they are the same on every node, `lease_sync_port`
  first.
- **sysupgrade with kept settings.** `/etc/hotplug.d/keepalived/` is kept
  as a whole for custom hooks; the upgrade script replaces the guard
  handler it finds there with the one of the new image at first boot.

## Dependencies

- `keepalived` - VRRP failover (required)

Used when installed:

- `owsync` - Bidirectional config file synchronization
- `lease-sync` and `dnsmasq-ha` (dnsmasq with ubus lease methods) -
  Real-time DHCP lease replication
- `luci-app-ha-cluster` - Web interface

## How It Works

ha-cluster reads `/etc/config/ha-cluster` and generates flat config files
for each service under `/var/run/ha-cluster/`:

```
/etc/config/ha-cluster  →  /var/run/ha-cluster/keepalived.conf
                        →  /var/run/ha-cluster/owsync.conf
                        →  /var/run/ha-cluster/lease-sync.conf
```

All three daemons are started as procd instances by ha-cluster. While it is
enabled, ha-cluster stops and disables the standalone `keepalived`, `owsync`
and `lease-sync` init scripts, and restores their previous state when it
stops.

Configuration changes are applied on reload (`reload_config`, or LuCI's
Save & Apply).

### Which daemons run

keepalived always runs while ha-cluster is enabled. The sync daemons run
only when they are installed, at least one peer with an address is not
`vrrp_only`, and:

- owsync: at least one enabled sync group lists files
- lease-sync: `lease_sync='1'`

A sync daemon that has work but is not installed is logged as a warning;
the cluster still starts.

As soon as one of them has work, a valid `encryption_key` is required:
without it ha-cluster refuses to start. Plain mode is an explicit choice,
`sync_encryption='0'`, never a fallback.

### Settings that must match on all nodes

`/etc/config/ha-cluster` is never synced (it is excluded by default), so
these settings must be set identically on every node:

- `encryption_key`, `vrrp_transport`, `lease_sync`, `sync_port`,
  `sync_dir`
- the sync groups and exclusions
- `lease_sync_port` (advanced)
- for each VRRP instance: `vrid`, `advert_int`, `auth_type`, `auth_pass`,
  and its VIPs

Node-specific: `node_priority` and instance `priority`, the peers, their
`source_address`, and `bind_address`.

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
uci set ha-cluster.lan.interface='lan'
uci set ha-cluster.lan.address='192.168.1.254'
uci set ha-cluster.lan.netmask='255.255.255.0'

# Apply
uci commit ha-cluster
reload_config
```

Repeat on each peer node with the appropriate priority and peer addresses.

## DHCP Prerequisites

When using lease sync (`lease_sync='1'`), each VIP interface must have
`force=1` in its DHCP configuration:

```sh
uci set dhcp.lan.force='1'
uci commit dhcp
```

**Why?** Without `force=1`, dnsmasq's init script probes for another DHCP
server on the interface, finds the peer, and leaves DHCP disabled there. This
prevents the ubus `add_lease` method from working — lease-sync cannot
inject leases into a node whose DHCP subsystem is not initialized. DNS
resolution for local hostnames would fail on the BACKUP node.

ha-cluster validates this at startup and refuses to start if `force=1` is
missing on any VIP interface with lease sync active.

Only set `force=1` on interfaces where you need HA DHCP. Other interfaces
(management networks, etc.) retain normal dhcp_check protection.

Every node serving DHCP must run dnsmasq non-authoritative: an
authoritative dnsmasq (OpenWrt's default) NAKs requests addressed to
another node, and clients may get no lease. Lease sync also needs
identical DHCP ranges on all nodes, so that the node taking over can
renew the synced leases; syncing `/etc/config/dhcp` provides that. On
every node:

```sh
uci set dhcp.@dnsmasq[0].authoritative='0'
uci commit dhcp
```

ha-cluster warns (in the log and in LuCI) when dnsmasq is authoritative
while several nodes serve DHCP, but never changes `/etc/config/dhcp`.

Keep a single enabled `dnsmasq` section on each node: lease-sync only
reaches the instance registered on ubus as `dnsmasq` (the others register
as `dnsmasq.<section>`), and ha-cluster writes its `script-on-renewal`
overlay to the conf-dir of the first section only.

Declare DHCP reservations as `host` sections of `/etc/config/dhcp`,
which the `dhcp` sync group keeps identical on all nodes, rather than in
`/etc/ethers`: dnsmasq reads that file too (`readethers`, on by
default), but it lies outside `sync_dir` (`/etc/config`), so owsync
cannot sync it.

## UCI Configuration

All configuration lives in `/etc/config/ha-cluster`.

### Global settings (`config global 'config'`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `0` | Enable/disable ha-cluster |
| `node_priority` | int | `100` | VRRP priority (1-255, higher wins MASTER) |
| `vrrp_transport` | string | `multicast` | VRRP transport: `multicast` or `unicast`. When `unicast`, instances without `unicast_peer` derive their addresses from the peers |
| `sync_method` | string | `owsync` | File sync backend; `owsync` is the only one, ha-cluster refuses to start with any other value |
| `sync_encryption` | bool | `1` | Encrypt owsync and lease-sync traffic (AES-256-GCM). With `1`, a sync daemon is not started without a valid `encryption_key`; `0` is the explicit choice of plain mode |
| `encryption_key` | string | | 256-bit hex key (64 hexadecimal characters); use LuCI "Generate" button or `hexdump -n 32 -v -e '1/1 "%02x"' /dev/urandom` |
| `lease_sync` | bool | `0` | DHCP lease sync (lease-sync and dnsmasq-ha); the shipped config sets it to `1` |
| `sync_port` | int | `4321` | owsync TCP port |
| `sync_dir` | string | `/etc/config` | Directory to synchronize |
| `bind_address` | string | | Local IP for sync traffic (use real IP, not VIP) |

### VRRP Instances (`config vrrp_instance '<name>'`)

Each section defines a VRRP instance. All VIPs referencing the same instance
fail over atomically as a group (one advertisement, one failover event).

With multicast VRRP, when any VIP in the group has `address6` set, a
second VRRP instance is created automatically using VRID+128 for all IPv6
VIPs. With unicast peers (`vrrp_transport` `unicast` or a `unicast_peer`
list), a single instance is created in the address family of
`unicast_src_ip`, or else of the first peer: the VIPs of the other family
fail over with it without being advertised, and peers of the other family
are ignored with a warning. A `unicast_src_ip` matching the family of no
peer is ignored with an error, and the first peer sets the family.

With `vrrp_transport` `unicast`, an instance without its own `unicast_peer`
list advertises to every peer `address` and, unless it sets
`unicast_src_ip`, from the first peer `source_address`. This derivation
fits only instances on the peers' network: an instance on another
interface sets both `unicast_peer` and `unicast_src_ip`.

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
| `interface` | string | | Logical interface (e.g. `lan`), resolved to its device |
| `address` | string | | Virtual IPv4 address |
| `netmask` | string | `255.255.255.0` | IPv4 netmask |
| `address6` | string | | Virtual IPv6 address (optional, uses VRID+128 with multicast) |
| `prefix6` | int | `64` | IPv6 prefix length |

### Peers (`config peer`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `name` | string | | Peer identifier |
| `address` | string | | Peer IP address |
| `source_address` | string | | Local IP to use when contacting this peer (the first one set is also the auto-derived `unicast_src_ip`) |
| `vrrp_only` | bool | `0` | Router not running ha-cluster (e.g. not OpenWrt): VRRP peer only, never synced |

### Sync groups (`config sync_group '<name>'`)

Each section lists files synced by owsync.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `1` | Enable sync for this group |
| `config_files` | list | | UCI config names or paths to sync |

### Exclusions (`config exclude`)

| Option | Type | Description |
|--------|------|-------------|
| `file` | list | Patterns (relative to `sync_dir`) to never sync; they take precedence over sync groups |

Default exclusions: `network`, `system`, `owsync`, `ha-cluster`, `wireless`.

`wireless` mixes per-node radio settings (`path`, `channel`) with shared
SSID/key data. To sync it anyway, remove its exclusion and add a sync group.

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

### Advanced settings (`config advanced 'advanced'`)

The section must carry the name `advanced`: the backend reads it by name
and ignores an anonymous one. A package upgrade names the anonymous
section that earlier releases shipped.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `log_level` | int | `2` | 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG |
| `owsync_log_level` | int | `2` | owsync log level |
| `sync_interval` | int | `30` | owsync poll interval (seconds) |
| `lease_sync_port` | int | `5378` | lease-sync UDP port |
| `lease_sync_interval` | int | `30` | lease-sync periodic sync (seconds) |
| `lease_sync_peer_timeout` | int | `120` | Peer timeout (seconds) |
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
- `ACTION` — `MASTER`, `BACKUP` or `FAULT`
- `TYPE` — `INSTANCE`
- `NAME` — instance name (e.g. `main`, or `main_v6` for its multicast IPv6 instance)

## Files

```
/etc/config/ha-cluster                  UCI configuration
/etc/init.d/ha-cluster                  procd init script (START=25, STOP=91)
/usr/lib/ha-cluster/ha-cluster.sh       Core library
/var/run/ha-cluster/                        Generated configs (runtime)
```

## License

MIT. See LICENSE file.

ha-cluster has been developed using Claude Code from Anthropic.

## Maintainer

Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
