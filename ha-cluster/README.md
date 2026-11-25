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
- **Firewall rules.** At its first start with this release ha-cluster adds
  rules named `HA-Cluster-...` to `/etc/config/firewall` and reloads the
  firewall, see [Firewall](#firewall). A cluster that works today already
  has what these rules allow, so nothing changes for its traffic; rules of
  your own for VRRP, owsync or lease-sync can go afterwards. Set
  `firewall '0'` before the upgrade to keep the firewall config as it is.
- **Advanced section.** Settings in an unnamed `config advanced` section
  were ignored by the 1.0.x backend and take effect once the section is
  named: check that they are the same on every node, `lease_sync_port`
  first.
- **Delegated LuCI users.** The ACL of luci-app-ha-cluster, as in upstream
  2.0.0, lets a user with its write role add health checks of
  `check_type 'command'`, which keepalived runs as root, and write the
  scripts of `/etc/hotplug.d/keepalived/`; its read role shows
  `encryption_key` and the VRRP `auth_pass`. Give these roles only to users
  who may be root on the router.
- **sysupgrade with kept settings.** `/etc/hotplug.d/keepalived/` is kept
  as a whole for custom hooks; the upgrade script replaces the guard
  handler it finds there with the one of the new image at first boot.
- **Settings put back after the migration.** The migration runs once, at
  the first boot of the image, and is then deleted. When the files it
  changed come back afterwards, ha-cluster finds the old model at its
  next start and migrates it then, with a warning in the log; it puts the
  guard handler of the release back in the same way. Two ways they come
  back: a backup of an earlier release restored in LuCI, and a first-boot
  script of your own that reboots, to grow the root partition for
  example. `/etc/init.d/done`, the last boot script, deletes the settings
  kept by sysupgrade (`/sysupgrade.tgz`); until a boot gets that far,
  preinit unpacks them again at every boot, over what the first-boot
  scripts of every package changed. Such a script should delete them
  before it reboots: `rm -f /sysupgrade.tgz && sync`. Until the config is
  migrated, `ubus call ha-cluster status` is `DEGRADED` and lists what it
  found under `earlier_model`, and LuCI's Status page says so.

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

**Files a peer sends are applied too.** owsync writes the files of the
sync groups that come from a peer, and removes those the peer removed, but
a config file under `/etc/config` takes effect only when the services that
read it are reloaded. ha-cluster gives owsync a program to run after a sync
session that changed files (`on_change` in `owsync.conf`, owsync 1.3.0-r6
of this feed): `/usr/lib/ha-cluster/owsync-changed` runs procd's
`reload_config`, as LuCI's Save & Apply does, which reloads each service
whose config changed: dnsmasq for `dhcp`, the firewall for `firewall`, and
so on. A burst of sessions is taken in one run, after a pause of two
seconds. Before, a DHCP pool or a firewall rule changed on one node
reached the other node's file and stayed out of its running service until
something else reloaded it.

### Which daemons run

keepalived always runs while ha-cluster is enabled. The sync daemons run
only when they are installed, at least one peer with an address is not
`vrrp_only`, and:

- owsync: at least one enabled sync group lists files
- lease-sync: `lease_sync='1'`, and the node runs dnsmasq as the DHCP
  server (see [Kea as the DHCP Server](#kea-as-the-dhcp-server))

A sync daemon that has work but is not installed is logged as a warning;
the cluster still starts.

As soon as one of them has work, a valid `encryption_key` is required:
without it ha-cluster refuses to start. Plain mode is an explicit choice,
`sync_encryption='0'`, never a fallback.

### Settings that must match on all nodes

`/etc/config/ha-cluster` is never synced (it is excluded by default), so
these settings must be set identically on every node:

- `encryption_key`, `vrrp_transport`, `lease_sync`, `sync_port`,
  `sync_dir`, `firewall`, `dhcp_backend` (and Kea's own setup)
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

## Kea as the DHCP Server

Only in this fork. ISC Kea can give out the IPv4 leases on the cluster
interfaces (the interfaces of the enabled VIPs) instead of dnsmasq. Option
`dhcp_backend` of the `config` section chooses:

| `dhcp_backend` | DHCP server of the cluster interfaces |
|---|---|
| `auto` (default, also when the option is absent) | Kea when its init script starts `kea-dhcp4` and `kea-dhcp4`'s config listens on the device of a cluster interface, unless Kea was stopped from luci-app-kea since; dnsmasq otherwise. Whether Kea runs is left to Kea's own settings |
| `kea` | Kea; ha-cluster turns `kea-dhcp4` on in `/etc/config/kea` and enables Kea's init script |
| `dnsmasq` | dnsmasq; ha-cluster turns `kea-dhcp4` off if it listens on a cluster interface |

The node switches at a start or reload of ha-cluster when the server asked
for is not the one it runs, see [Switching between dnsmasq and
Kea](#switching-between-dnsmasq-and-kea). Kea replicates its leases between
two servers itself, through its high-availability hook (`kea-hook-ha`), so
while a node runs Kea:

- lease-sync is not started, whatever `lease_sync` says, and the `force`
  option of the DHCP pools is not asked for;
- the `script-on-renewal` overlay of dnsmasq is removed;
- the warning about an authoritative dnsmasq is off;
- the IPv6 BACKUP guard no longer drops DHCPv6 requests on a BACKUP node.
  Kea decides by itself which server answers, whatever VRRP says, and a
  BACKUP may be the one. Router Advertisements stay guarded as before;
- the Status page and the `status` call name the server and say how
  `kea-dhcp4` and `kea-dhcp6` are doing, see
  [What the status says about Kea](#what-the-status-says-about-kea).

### Switching between dnsmasq and Kea

The switch covers DHCPv4. On the way to Kea, in this order:

1. **Kea is checked**: `kea-dhcp4` installed, its config listening on the
   device of every cluster interface where dnsmasq gives out addresses (in
   `interfaces-config`, or `"*"`), with a subnet for the interface's IPv4
   address. A config with comments, which jsonfilter cannot read, is
   searched as text and its subnets are not checked. A pool where dnsmasq
   also gives out DHCPv6 (Router Advertisements `server`, `dhcpv6` not
   `disabled`) stops the switch: with Kea, lease-sync no longer keeps those
   leases in step. Set `dhcpv6 'disabled'` first, or leave dnsmasq (see
   [IPv6 with Kea](#ipv6-with-kea-router-advertisements-and-dhcpv6)).
   **When what is missing is in Kea's config** (no config, the device or a
   subnet missing), and that config is still the sample of the Kea package
   (or missing), luci-app-kea's
   `/usr/libexec/luci-app-kea/setup-from-dnsmasq` (from 0.15.0) writes it
   from dnsmasq's pools and the nodes of the cluster, which ha-cluster gives
   it (`--cluster -`, the reply of the `nodes` call): the devices of the
   cluster interfaces, a subnet with the pool, lease time and options of
   each pool (routers and DNS the VIP when the pool names none), and Kea's
   high availability in hot-standby between the nodes. What it could not
   carry over is named in the log. Then Kea is checked again. A config of
   the user's own is never set up: the refusal says so, and it is fixed in
   luci-app-kea. A setup that fails stops the switch, nothing changed.
2. **dnsmasq's static leases are imported into Kea**, with luci-app-kea's
   `/usr/libexec/luci-app-kea/import-dnsmasq` (from 0.11.0), else its rpcd
   method; without luci-app-kea there is no import, and a warning. Only the
   entries Kea can take as they are; each one left (to review, that would
   change a reservation of Kea, or that cannot be taken) is named in the
   log and on the Status page, and the switch goes on: finish them on
   luci-app-kea's import page. An import that fails stops the switch.
3. **dnsmasq's DHCPv4 is switched off in the pools of the cluster
   interfaces**, the visible way: `dhcpv4 'disabled'` in the pool, as the
   DHCP page of LuCI shows it, with the value the pool had in
   `ha_cluster_dhcpv4` (`unset` when it had none). dnsmasq is restarted;
   DNS, the Router Advertisements and DHCPv6 stay as they were.
4. **Kea is restarted** (started, when it does not run), and given up to
   ten seconds to run with its sockets ready or retrying. A Kea started
   before, from luci-app-kea, could not bind its fallback socket while
   dnsmasq gave out DHCPv4 on the interface; the restart opens it. If it does not, the pools get their DHCPv4 back, what was
   changed in `/etc/config/kea` and Kea's init script is put back, dnsmasq
   stays the server, and the status says why (`dhcp_backend_problem`,
   `DEGRADED`). The switch is tried again at the next start or reload.
5. **dnsmasq's active leases are handed to Kea**, with
   `import-dnsmasq --leases` (luci-app-kea 0.15.0 and later), from a copy
   of dnsmasq's lease file taken before step 3 (in the run directory, 0600,
   removed afterwards), so that every client keeps its address at its next
   renewal. When that fails there is
   a warning only: Kea serves already, and gives a client its address again
   while nobody else has it.

dnsmasq is switched off before Kea starts: a few seconds without a DHCP
server rather than two of them. On the way back, Kea off first (with
`dnsmasq`), then the pools get their DHCPv4 back from `ha_cluster_dhcpv4`,
and dnsmasq is restarted. Kea's leases are not carried back to dnsmasq:
clients ask again; the static leases stay in `/etc/config/dhcp`.

The node remembers the server it runs in `/etc/ha-cluster/dhcp-backend`,
kept across sysupgrade. A node without that file, after an upgrade from a
release without switching, runs Kea if `dhcp_backend` is `kea` (and then
switches nothing: that was set up by hand) and dnsmasq otherwise.

**luci-app-kea's event.** From 0.11.0 luci-app-kea tells procd when it
has started, restarted, reloaded or stopped Kea (event `kea.service`), and
procd runs `/etc/init.d/ha-cluster kea_changed`: it notes whether Kea was
stopped on purpose and has a running cluster check its server, as a
reload does; a stopped cluster stays stopped. So with `auto`, starting Kea
in luci-app-kea hands the cluster interfaces to Kea within a second, and
stopping it hands them back to dnsmasq until Kea runs again, at the latest
after the next boot. Kea started or stopped by other means
(`/etc/init.d/kea`) is seen at the next start or reload of ha-cluster.

**The pair switches together.** Kea's high availability wants Kea on both
servers of a pair: a standby that starts takes the whole lease database
from its partner, then serves when the primary is gone. `/etc/config/dhcp`
is usually synced between the nodes, so the pools tell every node which
server the pair runs, and with `dhcp_backend 'auto'` a node follows a
switch made on the other node:

- the pools of the cluster interfaces arrive switched off for Kea
  (`ha_cluster_dhcpv4`) and none gives out DHCPv4, while this node runs
  dnsmasq: it switches to Kea, as with `kea` (including the setup from
  dnsmasq's pools when its Kea config is the package's sample). What it
  turned on in Kea's settings (kea-dhcp4 in `/etc/config/kea`, Kea's init
  script) is noted in `/etc/ha-cluster/kea-followed`;
- a pool gives out DHCPv4 again and none is switched off, while this node
  runs Kea: it switches back to dnsmasq, and turns off again what it had
  turned on.

A node that follows changes no pool: they are already as the other node
left them, so the nodes never undo each other. It does not follow while a
switch of its own was cut short (`switching`), while Kea was stopped on it
on purpose, or without `kea-dhcp4`. The change reaches it through procd:
`reload_config`, after LuCI's apply or owsync's `on_change`, sends
`config.change` for `dhcp`, and `/etc/init.d/ha-cluster dhcp_changed`
reloads the cluster when its server is not the one asked for. So switching
one node, with Kea set up or the setup from luci-app-kea at hand, switches
the pair within seconds.

With `dhcp_backend` set to `kea` or `dnsmasq` a node does as it is told and
follows nobody: a node that runs dnsmasq while the pools are switched off
for Kea, or one that runs Kea while a pool gives out DHCPv4, is `DEGRADED`
and says so. `/etc/config/ha-cluster` and Kea's config are not synced.

VRRP, the VIPs, file sync and the guard for Router Advertisements work as
with dnsmasq. Kea's primary need not be the VRRP MASTER: the clients reach
Kea by broadcast and multicast on the LAN, not through the VIP.

### IPv6 with Kea: Router Advertisements and DHCPv6

The switch moves DHCPv4 only. IPv6 on the cluster interfaces stays with
dnsmasq whichever server gives out the IPv4 leases. dnsmasq keeps sending
the Router Advertisements, with the prefix for SLAAC, the default route
and the DNS server (RDNSS). A client's SLAAC address does not change at a
switch, either way.

**Kea sends no Router Advertisements, and is not meant to.** In IPv6 the
Router Advertisement belongs to Neighbor Discovery (RFC 4861). The router
of each link sends it, and it is the only way a client learns its default
route: DHCPv6 (RFC 8415) has no option for a router, unlike option 3 of
DHCPv4. A DHCPv6 server is a separate service that may serve many links
from elsewhere, through relays, and ISC Kea is such a server, as ISC dhcpd
was before it. So a Kea DHCPv6 server always needs a router on the link
that sends Router Advertisements with the right flags:

| Flag | Tells the client |
|---|---|
| M (managed) | ask DHCPv6 for an address |
| O (other configuration) | ask DHCPv6 for options only (DNS, domain), not for an address |
| A (autonomous, per prefix) | build an address by SLAAC from this prefix |

Networks pair Kea with a separate source of Router Advertisements: radvd
on a Linux server; the router itself on a dedicated router (FRR, BIRD, a
vendor's "managed-config flag"); on OpenWrt odhcpd or dnsmasq.
dnsmasq sets the M flag only for a DHCPv6 range it serves itself, and the
O flag only for an `ra-stateless` one (`src/radv.c`). With
`dhcpv6 'disabled'` its advertisements carry neither, and dnsmasq cannot
serve DHCPv6 next to `kea-dhcp6` either: both want UDP port 547 on the
interface.

**What this means for a cluster:**

- **SLAAC only** (`ra 'server'` and `dhcpv6 'disabled'` in the pools, as in
  most home and small office networks): nothing to do. A switch to Kea and
  back leaves IPv6 as it was. Many clients use SLAAC only: Android has no
  DHCPv6 client at all, and the DNS server comes in the advertisement.
- **dnsmasq also gives out DHCPv6 addresses** (`ra 'server'` and `dhcpv6`
  `server` or not set, which dnsmasq's init script takes as SLAAC and
  DHCPv6): the switch is refused, as step 1 above says. With Kea,
  lease-sync does not run, so dnsmasq's DHCPv6 leases would no longer be
  kept in step between the nodes, and a node taking over would not know
  them. ha-cluster does not move DHCPv6 to Kea, and does not switch it off
  for you: set `dhcpv6 'disabled'` in the pools first, or stay on dnsmasq.
  Clients keep IPv6 by SLAAC once DHCPv6 is off; a client's DHCPv6
  address stays until its lease runs out.
- **DHCPv6 from Kea** is not set up by ha-cluster or by luci-app-kea's
  setup, and has not been tried in a cluster here. It needs, on every
  cluster interface:
  - a source of Router Advertisements that sets the M flag (and O) without
    serving DHCPv6 itself, sent by the VRRP MASTER only and from the
    link-local VIP: the guard drops Router Advertisements on a BACKUP, and
    on an interface with a link-local VIP those with any other source,
    whatever daemon sends them (nftables, output hook). dnsmasq
    cannot do this today (see above). odhcpd can (`ra 'server'`,
    `dhcpv6 'disabled'`, `ra_flags 'managed-config other-config'`), but it
    reads the same pool options as dnsmasq, which then must not send its
    own advertisements on that link;
  - `kea-dhcp6` with a `subnet6` for the prefix of the interface, and a
    high-availability relationship of its own (the hook is loaded per
    daemon: its own peers' URLs, for example port 8002, which the rule
    `HA-Cluster-Kea-HA` opens like those of `kea-dhcp4`). Kea does not
    follow the system's prefixes: a prefix delegated by the provider may
    change, and the `subnet6` has to change with it.

### What ha-cluster does for Kea

- **It tells Kea to read its config again when an interface has come up.**
  Kea opens its DHCP sockets on the devices as they are when it reads its
  config, and does not follow them. After netifd has made a device anew
  (`ifdown` and `ifup`, a network restart) Kea runs, reports its sockets as
  ready, and hears nothing. Its partner still reaches it over the HA link
  and so does not take over: the clients on that device lose their leases.
  `/etc/hotplug.d/iface/60-ha-cluster-kea` sends SIGHUP, on which Kea reads
  its config again and opens its sockets on the device as it is now, to
  each Kea DHCP daemon whose config names the device that came up (or
  `"*"`). Kea keeps its process and its leases; its high availability is
  back in step after a few seconds. A Kea that has only just started has
  no handler for the signal yet and would be ended by it, so the signal
  waits, up to ten seconds, until the process takes it.

  The signal is sent only when the device is another one than at its last
  ifup, which its index tells (remembered under
  `/var/run/ha-cluster/kea-devices/`): an interface that comes back on the
  device it had, as after a lost carrier, leaves Kea alone. The first ifup
  after boot counts as a new device. Reading the config again applies what
  the file holds by then: a change that was saved to `/etc/kea` and not
  yet applied takes effect at that moment, and with a file Kea cannot use
  it logs a failed reconfiguration and keeps the config it had.
- **It reports Kea in the cluster status**, and calls the cluster
  `DEGRADED` when Kea is the reason, see below.
- **It checks three things in the config of each enabled Kea DHCP daemon**
  (`/etc/kea/kea-dhcp4.conf`, `kea-dhcp6.conf`) at every start, and logs a
  warning for each that is missing; none stops the cluster:
  - the high-availability hook (`libdhcp_ha`): without it, and without a
    shared lease database, the leases stay on the node that gave them;
  - a port in every `"url"` of the hook. Kea takes `http://192.168.50.2/`
    as valid, then listens on a port the kernel picks and connects to port
    0 of its partner: such a pair never meets, and there is no port to
    open in the firewall;
  - `"service-sockets-max-retries"` in `interfaces-config`, with a number
    above zero. A Kea that cannot open a socket at its start, as at boot
    when it starts before the interface is up or before the IPv6
    link-local address is usable, gives up for good unless this is set.
    Something like `"service-sockets-max-retries": 60` with
    `"service-sockets-retry-wait-time": 2000` is enough.
- **It warns when kea-dhcp4 listens on a cluster device without an
  address** (`"br-lan"`, or `"*"`) while a VIP is on it. Kea opens a socket
  for each IPv4 address of a device named alone, each one taking the
  broadcasts, so every request of a client is taken and answered once per
  address: the node's own, and the VIP's on the MASTER. Name the device with
  the node's own address, which stays on the node (`"br-lan/192.168.1.2"`);
  the warning gives it. luci-app-kea's setup writes it so from 0.15.1.
- **It names the nodes for Kea's HA setup**, see
  [Setting up Kea's high availability](#setting-up-keas-high-availability).

What ha-cluster does not do for Kea:

- It does not configure Kea. Set up the subnets and the high-availability
  hook in Kea on every node, with the peers' addresses on the link the nodes
  sync over (luci-app-kea does it). With `auto` it starts Kea only when Kea
  is set to run and does not; with `kea` and `dnsmasq` it turns
  `kea-dhcp4` on or off in `/etc/config/kea` and restarts Kea. DHCPv6 of
  Kea is left as Kea has it.
- It does not choose the ports of Kea's HA listeners: they are in the
  `"url"`s of Kea's config. It opens them for the nodes, see
  [Firewall](#firewall), and learns of a changed port at its next start or
  reload, or when told: run `/etc/init.d/ha-cluster firewall` after
  applying changed URLs in Kea.
- It does not sync Kea's configuration: owsync works inside `/etc/config`,
  and Kea keeps its files in `/etc/kea`.
- It does not carry leases over when the server changes: clients ask
  again.
- It does not hand the names of Kea's clients to dnsmasq's DNS: dnsmasq
  answers for the names of its own leases only. Package
  [`kea-dnsmasq-hosts`](../kea-dnsmasq-hosts/README.md) does.

At every start ha-cluster also logs a warning when neither Kea DHCP daemon
is installed, and when a dnsmasq pool on a VIP interface still answers
DHCPv4. Neither stops the cluster.

Back to dnsmasq: set the option to `dnsmasq` (or, with `auto`, stop Kea
in luci-app-kea), and apply. lease-sync starts again if `lease_sync` is
`1`, and the guard drops DHCPv6 on a BACKUP again.

### What the status says about Kea

`ubus call ha-cluster status` gives `dhcp_backend`, the server the node
runs (`dnsmasq` or `kea`), and `dhcp_backend_mode`, what the config asks
for (`auto`, `dnsmasq`, `kea`). `dhcp_backend_problem`, when present, says
why the server asked for is not the one in use, or what the pools say
against it; the cluster is then `DEGRADED`. After a switch to Kea,
`kea_import` gives the number of dnsmasq's static leases the import left
(`left`) and the first 50 of them (`entries`: `name`, `identifier`,
`address`, `status`).

It lists `kea-dhcp4` and `kea-dhcp6` under `services` when the node runs
Kea:

| Field | Meaning |
|-------|---------|
| `installed`, `running`, `pid`, `uptime` | as for the other services |
| `enabled` | the daemon's section in `/etc/config/kea` is there and not disabled |
| `sockets` | `ready`, `retrying` or `failed`, as Kea says it: the last two mean that at least one of its DHCP sockets is not open |
| `sockets_error` | the reason Kea gives for a device of the cluster, else the first reason it gives |
| `ha` | `mode`, `state` and `role` of this server in Kea's high availability, `partner_in_touch`, `partner_state`; absent when the hook is not loaded |
| `problem` | absent, or why this node is not a full member of the DHCP pair |

`sockets` and `ha` come from Kea itself, asked on its control socket
(`/var/run/kea/kea4-ctrl-socket`, `kea6-ctrl-socket`, the names of the Kea
package). This needs the ucode socket module, package `ucode-mod-socket`;
without it, or with other socket names, the entry stops at `running`.

`problem` is set for an enabled daemon only, and makes the cluster
`DEGRADED` unless it is `FAULTY` or `STOPPED` for another reason:

| `problem` | When |
|-----------|------|
| `stopped` | enabled in Kea's config and not running |
| `not-listening` | running, and a socket is not open on a device the cluster has an instance or a VIP on |
| `ha-terminated` | Kea has ended its high availability, as it does when the clocks of the two servers are more than 60 seconds apart |
| `partner-down` | Kea serves alone |

Kea calls its sockets `failed`, or `retrying`, as soon as one of them is
not open, on whatever interface its config lists, and goes on listening on
the others: an interface without an address in the list is enough, and with
`"*"` any interface of the node. Each of Kea's reasons names its interface,
and `not-listening` is set when one of them names a device of the cluster,
or when Kea gives no reason at all. A socket that failed elsewhere shows in
`sockets` and `sockets_error` and is not held against the cluster.

A Kea without the hook, and one that cannot be asked, are reported as they
are and not held against the cluster either. `sockets` says what Kea
believes: the deafness after a device was made anew does not show there,
which is why ha-cluster makes Kea reopen its sockets instead of looking for
it.

### Setting up Kea's high availability

Kea wants, in the config of both servers, the same list of servers with a
name and a URL each, and its own name in `this-server-name`.
`ubus call ha-cluster nodes` gives what a pair needs from the cluster's
side:

```json
{
	"dhcp_backend": "kea",
	"node": {
		"name": "ha-192-168-50-2",
		"label": "node1",
		"address": "192.168.50.2",
		"priority": 100,
		"kea_role": "primary"
	},
	"peers": [
		{
			"name": "ha-192-168-50-3",
			"label": "node2",
			"address": "192.168.50.3",
			"vrrp_only": false,
			"kea_role": "standby"
		}
	],
	"dhcp_interfaces": [
		{
			"interface": "lan",
			"device": "br-lan",
			"vip4": [ "192.168.50.1" ]
		}
	]
}
```

`dhcp_interfaces` lists the cluster interfaces a DHCP server serves (those
of the enabled VIPs, the logical interface also when a VIP names its
device), each with its device (empty when the network config does not
give it) and the IPv4 addresses of its VIPs, without mask: what
luci-app-kea's setup builds the subnets on.

- `name` is made from the address a node is reached at by its peers, so
  every node gives every node the same name. `label` is the host name of
  this node and the configured name of a peer.
- `address` of `node` is this node's own address towards its first sync
  peer: the peer's `source_address`, else `bind_address`, else the one the
  kernel routes with. It is never a VIP as long as one of the first two is
  set.
- `kea_role` is a suggestion for hot-standby: the node whose name sorts
  first is `primary`, the next `standby`, any further one `backup`. Every
  node sorts the same names, so they agree without knowing each other's
  VRRP priority. A peer with `vrrp_only` takes no part.

The call only reads the ha-cluster config and writes nothing. The mode, the
ports and the URLs are Kea's to choose.

Tried with Kea 3.0.4 in hot-standby on a pair of OpenWrt 25.12.6 x86_64
guests, DHCPv4 and DHCPv6, leases of 120 seconds: with Kea's primary on
the VRRP BACKUP the client got and renewed its addresses; Kea's primary
stopped for three minutes, the node cut off for two and a half, the node
rebooted: the client kept both addresses each time. Kea of the OpenWrt
package keeps its lease files in `/var/lib/kea`, which is in RAM: after a
reboot a node has the leases its partner sends it, and after both nodes
were down at once there are none, as with dnsmasq's lease file.

## Uplinks: interfaces that follow the role (Advanced Multi-WAN Management)

An uplink section names an interface of `/etc/config/network` that follows
this node's VRRP role. It is meant for a line or a login that allows one
session, such as PPPoE: only the MASTER dials. LuCI has it under High
Availability → Advanced Multi-WAN Management, which lists every WAN
interface (those of mwan3 and of the firewall zones that masquerade) in
mode `unmanaged` until a mode is chosen.

```
config uplink 'wan'
	option interface 'wan'
	option vrrp_instance 'lan'
	option mode 'master'

config uplink 'wanb'
	option interface 'wanb'
	option mode 'always'
```

- **`master`**: the interface is up only while this node is MASTER of
  the keepalived instance of `vrrp_instance`. It goes down at once in
  BACKUP and FAULT, when the service stops, and during a hand-over. `ifdown`
  ends a PPPoE session with PADT, so the provider frees it for the peer.
- **`unmanaged`**: listed only; ha-cluster leaves the interface alone, as
  without a section, and gives a `master` interface its `auto` back.
- **`always`**: the interface is up on every node whatever the role.
  ha-cluster only watches it. When a node that is not MASTER has lost it
  for longer than `grace`, the status warns: a failover would leave the new
  MASTER without it.

An uplink follows the role and never changes it. A MASTER whose uplink does
not come up stays MASTER and the status turns `DEGRADED` after `grace`.
Moving the role because of an uplink would only make the nodes hand it back
and forth: when the line or the login is the problem, the peer fails too,
and each move is a new wait at the provider.

**At boot.** An interface with a `master` uplink gets `auto '0'` in
`/etc/config/network`. Otherwise netifd would bring it up on every node
before VRRP has chosen the MASTER. The value it had is kept in
`ha_cluster_auto` (`unset` when it had none). It is given back when the
uplink is disabled or removed, is moved to `always`, or the node leaves the
cluster (HA disabled, the service disabled, also after a stop). The interface is then brought
up if that value asks for it. netifd is told to read the network config
again when `auto` changes. Otherwise a later reload of the network would
take the interface down once.

**Retries.** netifd retries a protocol by itself as long as the interface
is up on its side. A PPPoE server that refuses or does not answer gets
another attempt at once. ha-cluster brings the interface up once and
watches. It brings it up again, every `retry` seconds, only when netifd has
stopped trying: after an authentication failure on an interface with
`option authfail '1'`, or after someone's `ifdown`. It does not retry after
an error of the interface's configuration (`OPTION_ERROR`). With one session
per login, `authfail '1'` on the interface is worth setting: without it,
netifd asks the provider every few seconds while the provider still holds
the old session, and some providers lock a login after many failed
attempts.

**Not on the cluster's own interfaces.** A `master` uplink may not name
loopback, the interface of a VRRP instance or of a VIP (named, or holding
the addresses of the device they name: a PPPoE session on that device is
allowed, it has a device of its own), or the sync link (the interface carrying `bind_address` or a
peer's `source_address`): it would go down on the BACKUP and stay down at
boot. The validation refuses it, LuCI too, and the rounds that read the
config on their own leave it alone. Mode `always` only brings an interface
up and may name any.

**By hand.** An interface brought up on a node that is not MASTER (LuCI's
Connect, `ifup`) is taken down again within a few seconds, with a warning in
the log. To manage the interface by hand, disable its uplink section.

**Hooks of your own.** A handler in `/etc/hotplug.d/keepalived/` that brings
the same interface up or down at VRRP changes would act on it besides
ha-cluster. The start warns about it, and so does the Advanced Multi-WAN Management page:
remove it once an uplink section manages the interface.

**How it runs.** keepalived reports each state change through
`/etc/hotplug.d/keepalived/10-ha-cluster-role`. That handler records the
state and brings the uplinks in line at once. The service also runs a
monitor (procd instance `monitor`) that does the same every five seconds
and checks the states recorded against keepalived's every minute. Routes
and load balancing between several uplinks stay with mwan3, which follows
the interfaces going up and down.

The status (`ubus call ha-cluster status`, LuCI's Status page) lists each
uplink with its role, what it should be (`up`, `down`, `wait` during
`up_delay`), what it is (`up`, `connecting`, `retrying`, `down`), netifd's
last error, ha-cluster's attempts and how long it has been down.

## Maintenance

A node in maintenance hands its VRRP roles, its part of DHCP (Kea) and its
`master` uplinks to the peer. There are two modes, as pfSense has them:

| | Until reboot (`temp`) | Persistent (`on`) |
|---|---|---|
| Mark | `/var/run/ha-cluster/maintenance` | `option maintenance '1'` in `config global` |
| After a reboot or upgrade | gone: the node rejoins, and takes the role back if preemption allows | kept: the node does not take the role back until you leave maintenance |
| VRRP | every instance in FAULT: the node is no candidate | every instance at the lowest priority: the node stays the last candidate |
| The peer fails meanwhile | no node holds the role until `off` | this node takes over, and its Kea serves again |
| For | an upgrade with a reboot after which the node may rejoin by itself; a short check | work after which the node must be checked before it gets the role back; several reboots |

```
/etc/init.d/ha-cluster maintenance temp    # until off or the next reboot
/etc/init.d/ha-cluster maintenance on      # until off, across reboots
/etc/init.d/ha-cluster maintenance off
/etc/init.d/ha-cluster maintenance         # prints none, temp or persistent
```

LuCI's Status page has the same three buttons. Entering is refused while the
peer could not take over: a peer that does not answer ping, or, with Kea, a
partner out of touch or itself in maintenance. `force` (the button LuCI
offers after a refusal) enters anyway. keepalived does not tell this node
whether the peer is in maintenance, so without Kea the check is ping only:
do not put both nodes in maintenance.

One maintenance command runs at a time: a second one, from LuCI, the
command line or a sysupgrade, is refused while the first runs, and LuCI
greys its buttons meanwhile. The last command's result is in the status
(`maintenance_result`). Going from persistent maintenance to maintenance
until reboot is checked like entering: in persistent maintenance the node
is still a candidate.

What entering does, in this order:

1. **Kea**: this node's server goes `in-maintenance`. Its partner sees that
   at its next heartbeat and goes `partner-in-maintenance`, serving every
   client. Kea takes `ha-maintenance-start` only from the control socket of
   the server that stays, so the node does from its side what that command
   would make the partner do.
2. **Uplinks**: the `master` uplinks go down while the node still holds the
   role. The session is closed (PADT) before the peer dials.
3. **VRRP**: keepalived follows two files (`track_file`) that its config
   names only during a maintenance. Every instance goes to FAULT and the
   peer takes the VIPs at once, even with `nopreempt`. In persistent mode
   the instances then come back as BACKUP with 253 taken off their
   priority.

Leaving gives the instances their priorities back, takes the marks away,
puts this node's Kea back in the state it had and sends `ha-reset` to the
partner's HA listener. The partner leaves `partner-in-maintenance` for
`waiting` and syncs with this node. The partners come from the config the
running Kea holds (`config-get`), and ha-cluster sends `ha-reset` only to
plain HTTP at the address of a peer of the cluster, on a port the firewall
rule of Kea's HA opens; a partner it does not reach this way stays
`partner-in-maintenance`, and this node's Kea goes back in-maintenance at
its next heartbeat. ha-cluster checks that after eight seconds, does it once
more, and otherwise logs that `ha-maintenance-cancel` must be run on the
partner. `maintenance off` also brings back a Kea of this node left
in-maintenance without a maintenance of the node. A node that leaves the
cluster (HA disabled, the service disabled) ends its maintenance.

With `priority 255` (the address owner) keepalived ignores weighted
tracking and resets `nopreempt`: during a maintenance the generated config
has 254, so that persistent maintenance demotes the node. Whether the node takes the
role back is VRRP's decision: at once with preemption, not with
`nopreempt`.

**sysupgrade.** A sysupgrade that keeps the settings puts the node in
maintenance until reboot first (`/lib/upgrade/ha-cluster.sh`), once the image
has been checked: Kea's partner takes over, the `master` uplinks go down
(PADT), and the peer becomes MASTER. It runs among the hooks that
`/sbin/sysupgrade` calls while it writes the backup of the settings, takes
40 seconds at most (its own timer) and never stops the upgrade. It cannot wait any longer:
as soon as `/sbin/sysupgrade` hands the image to procd, procd stops every
service with a signal, netifd and pppd go without a PADT, and the provider
holds the session. That is what refused the peer's PPPoE for minutes before.
An upgrade that writes no backup gets no hand-over: without the settings
(`sysupgrade -n`) or with the settings of an archive (`sysupgrade -f`). Run
`maintenance temp` first. If an upgrade fails after the
hand-over, the node stays in maintenance until `maintenance off` or a
reboot, as its status says.

An upgrade of the pair, then:

1. upgrade the BACKUP;
2. on the MASTER, `maintenance on`, and check that the peer serves LAN,
   DHCP and WAN;
3. upgrade the node in maintenance;
4. `maintenance off`.

## Firewall

Only in this fork. The nodes of a cluster talk to each other, and a
firewall zone that rejects input stops them: without VRRP adverts every node
becomes MASTER, without their ports owsync, lease-sync and Kea's high
availability see no peer. ha-cluster keeps what the cluster needs as
ordinary rules in `/etc/config/firewall`. They are named `HA-Cluster-...`
(sections `ha_cluster_...`) and show wherever rules show: LuCI under
*Network → Firewall → Traffic Rules*, `uci show firewall`, and, with their
packet counters, `nft list chain inet fw4 input`.

| Rule | Lets in | From |
|------|---------|------|
| `HA-Cluster-VRRP-<device>` | VRRP (protocol 112), and AH (51) where an instance on that device uses `auth_type 'ah'` | anyone on the device of the instance: the adverts come from the nodes' addresses on that device, which the config does not name |
| `HA-Cluster-owsync` | TCP `sync_port`, when owsync has work | the nodes that sync |
| `HA-Cluster-lease-sync` | UDP `lease_sync_port`, when lease-sync has work | the nodes that sync |
| `HA-Cluster-Kea-HA` | TCP, the ports of the `"url"`s in the config of each enabled Kea DHCP daemon, while the node runs Kea; not a port below 1024 nor those of owsync and lease-sync, which a warning names | the nodes that sync |
| `HA-Cluster-Kea-HA-drop` | nothing: drops TCP to those same ports, right after the rule above | anybody else, whatever the zones accept |
| `HA-Cluster-ping` | ICMP and ICMPv6 echo requests, which the status uses to see a peer | all nodes |

"The nodes" are the peers' addresses and this node's own address towards
each peer: the peer's `source_address`, else `bind_address`, else the one
the kernel routes with. With both in every rule, every node writes the same
rules, and a firewall config that owsync carries from node to node is right
on each of them; rules without the node's own address would differ from
node to node and the synced file would change back and forth. The rules
accept from any zone (`src '*'`): the link the nodes sync over may be in
any zone. Only the addresses of the nodes get through, and of what a
spoofed address could send, TCP gets no answer to complete a connection
and the datagrams of lease-sync are authenticated; Kea's high availability
is not (see the notes on Kea below). Kea's listener takes commands from
whoever connects, `dhcp-disable` and lease changes among them: Kea 3.0.4
does not check basic-auth on it, only mutual TLS. A zone that accepts
input from its clients (OpenWrt's `lan`) would let them reach it at a
node's sync address, so `HA-Cluster-Kea-HA-drop` drops every connection
to its ports that the rule before it did not accept.

What the clients need (DHCP, DNS, Router Advertisements) is not in these
rules: that is the business of the zone the clients are in, as it is
without a cluster.

How the rules are kept:

- They are written at every start and reload of ha-cluster, and only when
  they differ from what the config holds; the firewall is reloaded when
  they were written, or when they are in the config and not in the loaded
  ruleset (as after owsync brought the config from another node).
- They are rules of ha-cluster: a change made to one by hand, or another
  section named `ha_cluster_...`, is undone at the next start. Rules of
  your own under other names are left alone, and so are changes you have
  staged in LuCI and not yet applied: ha-cluster writes its rules on a copy
  of the committed file, not through uci's pending changes, which `uci -t`
  does not keep apart (uci applies the pending changes of `/tmp/.uci` with
  any save directory, and a commit would take them into the file). The
  copy replaces the file under its lock, as uci does, and only if the file
  has not changed meanwhile; otherwise the rules are written again on what
  it holds then. The same goes for what the switch of the DHCP server
  writes to `/etc/config/dhcp` and `/etc/config/kea`.
- Before the firewall is reloaded with new rules it is checked
  (`fw4 check`); if the check fails the rules are taken out again and an
  error is logged, since a config firewall4 cannot load would keep the
  whole firewall from loading.
- `/etc/init.d/ha-cluster stop` leaves them in place while the node is
  still part of the cluster (Kea's high availability and the peer's ping
  do not stop with ha-cluster). They are removed when the node leaves: HA
  disabled in the config, the service disabled, or the package removed.
- When this node's own address towards a peer is not known, which happens
  at boot before the interface is up if neither `source_address` nor
  `bind_address` is set, rules written earlier are left as they are; if
  there are none yet, none are written and a warning says so. Setting
  `bind_address` avoids the question.
- `option firewall '0'` in the `config` section ("Firewall Rules" on the
  General page of LuCI) removes the rules and leaves the firewall to you.
  With a synced firewall config, set it alike on all nodes.
- `/etc/init.d/ha-cluster firewall` brings the rules up to date and does
  nothing else: no daemon is started, stopped or signalled, whether the
  service runs or not, and nothing happens for a cluster that is switched
  off. It is what to call when something outside the config of ha-cluster
  changed what the rules must say, such as the ports of Kea's high
  availability; `reload` would start a service that was stopped on
  purpose.

Tried on pairs of OpenWrt 25.12.6 x86_64 guests with the LAN between the
nodes in a zone with `input 'REJECT'`. Without the rules both nodes were
VRRP MASTER, each saw its peer as offline, and two Kea servers that had to
connect anew were both `partner-down`; with the rules one MASTER, the peer
online, Kea in `hot-standby`. With dnsmasq and lease-sync, and the dhcp and
the firewall config synced by owsync: a change to the dhcp config reached
the other node, the firewall config stayed the same file on both, a
datagram to the port of lease-sync was let in from a node and rejected from
a client, and a rebooted node came back as BACKUP with the rules loaded by
the firewall itself and nothing written again.

A connection that is already open goes on when the rules are taken away:
the firewall accepts established flows before it looks at any rule. What
the rules decide is whether the nodes can connect anew.

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
| `dhcp_backend` | string | `auto` | DHCPv4 server of the cluster interfaces: `auto` (Kea once it is set up and started for a cluster interface, else dnsmasq), `dnsmasq` or `kea`; the node switches at a start or reload. With Kea, lease-sync does not run, Kea is reported in the status and told to reread its config when an interface it listens on comes up; ha-cluster refuses to start with any other value. See [Kea as the DHCP Server](#kea-as-the-dhcp-server) |
| `sync_port` | int | `4321` | owsync TCP port |
| `sync_dir` | string | `/etc/config` | Directory to synchronize |
| `bind_address` | string | | Local IP for sync traffic (use real IP, not VIP) |
| `firewall` | bool | `1` | Keep the rules the cluster needs from its peers in `/etc/config/firewall` (rules named `HA-Cluster-...`); `0` removes them. See [Firewall](#firewall) |
| `maintenance` | bool | `0` | Persistent maintenance, written by `/etc/init.d/ha-cluster maintenance on` and removed by `off` (with `maintenance_since`, when it began). See [Maintenance](#maintenance) |

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
| `config_files` | list | | Names of files in `/etc/config` to sync (e.g. `dhcp`), patterns allowed. owsync syncs nothing outside `/etc/config`: an entry that starts with `/` matches nothing, and ha-cluster warns about it at start |

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

### Uplinks (`config uplink '<name>'`)

See [Uplinks](#uplinks-interfaces-that-follow-the-role-advanced-multi-wan-management).

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | bool | `1` | Manage the interface |
| `interface` | string | | Logical interface of `/etc/config/network`; one uplink section per interface |
| `mode` | string | `master` | `master`: up only on the MASTER of `vrrp_instance`; `always`: up on every node, watched; `unmanaged`: listed only, not touched (what LuCI writes for a WAN interface left alone) |
| `vrrp_instance` | string | | The `vrrp_instance` section whose role the uplink follows; required in mode `master` |
| `up_delay` | int | `0` | Seconds after becoming MASTER before the interface is brought up (0-3600); 5-10 when the role flaps |
| `grace` | int | `180` | Seconds the interface may be down while it should be up before the status says so (0-86400) |
| `retry` | int | `30` | Seconds between ha-cluster's own attempts once netifd has stopped trying (5-3600) |

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

ha-cluster installs two handlers there: `10-ha-cluster-role` (uplinks,
Kea during a maintenance) and `20-ipv6-backup-guard`.

Available environment variables:
- `ACTION` — `MASTER`, `BACKUP` or `FAULT`
- `TYPE` — `INSTANCE`
- `NAME` — instance name (e.g. `main`, or `main_v6` for its multicast IPv6 instance)

## Files

```
/etc/config/ha-cluster                  UCI configuration
/etc/init.d/ha-cluster                  procd init script (START=25, STOP=91)
/usr/lib/ha-cluster/ha-cluster.sh       Core library
/usr/lib/ha-cluster/migrate-config      The upgrade's migration, for a config put back after it
/etc/ha-cluster/dhcp-backend            The DHCP server the node runs (dnsmasq or kea), kept across sysupgrade
/etc/hotplug.d/iface/60-ha-cluster-kea  With Kea as the DHCP server: Kea rereads its config at ifup
/etc/hotplug.d/keepalived/10-ha-cluster-role  Runs /usr/lib/ha-cluster/role at each VRRP state change
/usr/lib/ha-cluster/role                The uplinks and Kea at VRRP changes; the uplink monitor
/lib/upgrade/ha-cluster.sh              Hands the roles over at a sysupgrade (maintenance until reboot)
/var/run/ha-cluster/                        Generated configs (runtime)
```

## License

MIT. See LICENSE file.

ha-cluster has been developed using Claude Code from Anthropic.

## Maintainer

Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
