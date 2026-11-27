# Changelog

All notable changes to this feed are documented in this file. Each entry
is a feed release (git tag `vX.Y.Z`) and lists the package versions it
ships. lease-sync and owsync live in their own repositories: this file
gives their version and links to their changelog.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Feed tags follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):
the major version changes when an upgrade needs action (configuration
schema change, all nodes upgraded together). Each package keeps its own
version.

## Fork changes (woffko/openwrt-ha-feed) on top of 2.0.0

This fork merges upstream 2.0.0 and carries the changes below. Its
packages are `ha-cluster` 2.0.0-r28, `luci-app-ha-cluster` 2.0.0-r18,
`lease-sync` 1.2.1-r6, `owsync` 1.3.0-r6 and `dnsmasq-ha` 2.93-r5. See
[Notes for this fork](ha-cluster/README.md#notes-for-this-fork) before
upgrading a node.

### Repository
- The fork is on its `master` branch since 2026-11-27. The branches it was
  developed on (`feature/dhcp-backend-kea`, `port/upstream-2.0.0-model`
  and the earlier ones) were merged into it and removed: a `feeds.conf`
  that names one of them should name `master`, or a commit.

### ha-cluster
- Uplinks (`config uplink`): interfaces that follow the node's VRRP role.
  In mode `master` an interface, such as a PPPoE line with one session per
  login, is up only on the MASTER of the instance it follows; in mode
  `always` it is up on every node and watched. ha-cluster sets `auto '0'`
  on the interface of a `master` uplink and keeps the value it had in
  `ha_cluster_auto`, takes down an interface brought up by hand on a node
  that is not MASTER, brings it up again when netifd has stopped retrying,
  and reports each uplink in the status: `DEGRADED` when the MASTER has
  been without it longer than `grace`. An uplink never moves the role.
  Mode `unmanaged` (r24) lists an interface without touching it. See
  [Uplinks](ha-cluster/README.md#uplinks-interfaces-that-follow-the-role-advanced-multi-wan-management).
- Maintenance, in two modes as pfSense has them:
  `/etc/init.d/ha-cluster maintenance temp` (until reboot: every instance
  in FAULT) and `maintenance on` (kept across reboots: the lowest
  priority, the node stays the last candidate), `maintenance off` to
  leave. Kea's partner is made to serve every client first, the `master`
  uplinks go down before the peer dials, and entering is refused while
  the peer could not take over, unless forced. The status is
  `MAINTENANCE`. See [Maintenance](ha-cluster/README.md#maintenance).
- Fixes from the full code audit of the w0w6 build (r26, LuCI r17):
  - a sysupgrade that stops after the hand-over (a failed backup, rpcd's
    30 s limit) leaves no stale MASTER: the states recorded say STOP, so
    `maintenance off` brings no `master` uplink up while the peer holds
    the session, and it starts the service again when nothing of it runs
    in procd; the IPv6 guard closes at the hand-over; LuCI's web server
    starts again after 150 seconds if the upgrade does not go on;
  - the hooks of keepalived-sync, kept by sysupgrade from an image that
    had the package, are removed once it is gone (each loads its missing
    library); the role handler `10-ha-cluster-role` is put back when it is
    missing, as the guard handler is, and LuCI's hook editor hides both;
  - `ha-reset` goes only to a peer's address (no longer this node's own
    `source_address`, nor a VRRP-only peer), with no path but `/`;
  - the locks of the DHCP server switch, of the firewall rules and of
    owsync-changed are in the run directory (0700), not in `/var/lock`;
    the firewall lock is bounded to 30 seconds;
  - priority 255 is offered no more (1-254); a config that has it gets
    254 in keepalived, which takes 255 for the owner of the addresses and
    then ignores `nopreempt` and the weights of the checks;
  - the views put status and config data in as text, not as HTML.
- r27, from the re-audit of that build:
  - the timer that starts LuCI's web server again after a sysupgrade that
    did not go on acts only while the mark of its own hand-over stands
    (`uhttpd-restore` in the run directory): the timer of a failed attempt
    no longer starts the server under a later attempt, where the flash
    page would take the device as rebooted; `maintenance` takes the mark
    away and starts the server at once;
  - the hand-over of a sysupgrade runs under the lock of the maintenance
    commands. It waits five seconds for a command that runs, then goes on
    without the lock, because the upgrade goes on in any case.
- r28, from a joint review with the auditor of that build:
  - `maintenance` on a node whose Kea was not running did not return for
    two minutes, and a Kea started afterwards served while the node was
    in maintenance. The wait that puts Kea back in-maintenance ran as a
    copy of the shell that called it and kept that shell's output and the
    lock rc.common holds during a start or a reload, so the command, and
    every other call of `/etc/init.d/ha-cluster`, waited for it. It is a
    process of its own now (`role kea-resume`); the background reconcile
    and the IPv6 guard handler no longer inherit that lock either. The
    monitor also looks once a minute for a Kea that serves during a
    maintenance and puts it back, and runs whenever Kea is the DHCP
    server, not only with uplinks;
  - the sysupgrade hook stops LuCI's web server only when it runs: one
    the user had stopped or disabled was started by the hook's timer or
    by `maintenance`. A second attempt takes over the mark of the first;
  - `maintenance` ignores Ctrl-C and a lost SSH session while it hands
    the roles over (a hand-over cut short left the `master` uplinks held
    and, in persistent mode, the node in FAULT);
  - the hand-over of a sysupgrade gives the maintenance lock back by
    name, and the work under the role lock no longer carries it along;
  - the states recorded for instances that the keepalived config no
    longer has are removed at a start, a reload and the monitor's check;
  - a switch to Kea that is refused on a node whose pools arrived
    switched off from the other node no longer says "dnsmasq stays the
    DHCP server": the node has none for those pools until Kea runs.
- r25: the hand-over at a sysupgrade is quick (a few seconds: the mark,
  Kea with four seconds for its partner, the uplinks down, keepalived
  removed from procd) instead of a full maintenance with a reload of the
  service. Flashed from LuCI on the routers, the full one went past the 30
  seconds after which rpcd kills sysupgrade: the node handed its roles over
  and never upgraded. LuCI's web server stops first, so that the flash page
  waits for the reboot instead of going to the overview.
- A sysupgrade that keeps the settings puts the node in maintenance until
  reboot first (`/lib/upgrade/ha-cluster.sh`, among the hooks
  `/sbin/sysupgrade` runs once the image is checked), so the peer serves at
  once and finds the PPPoE sessions closed. Before, procd stopped every
  service with a signal, pppd went without a PADT, and the peer's PPPoE
  was refused while the provider held the old session.
- Fixes from the third code audit (r23):
  - a `master` uplink may not name loopback, the interface of a VRRP
    instance or of a VIP, or the sync link: it would go down on the BACKUP
    and stay down at boot (and a delegated LuCI user could change
    `/etc/config/network` through it); refused at validation and in LuCI,
    and left alone by the rounds that read the config on their own;
  - `disable` of a stopped service releases what the stop kept for a node
    that stays: the auto of the uplinks, the IPv6 guard, the firewall rules,
    a maintenance; a node that leaves the cluster ends its maintenance;
  - the locks of the uplinks and of maintenance are in the run directory
    (0700), not in `/var/lock`, and bounded; one maintenance command at a
    time, Kea's resume under the same lock, the result written by the
    command itself;
  - going from persistent maintenance to maintenance until reboot checks
    the peer too; the check refuses a Kea of this node that does not
    answer and a partner that does not serve every client;
  - the mark of a maintenance is written first, and the hold of the
    uplinks never outlives a failed hand-over;
  - leaving maintenance checks that Kea is out after eight seconds and does
    it once more; the partners come from the running Kea (`config-get`)
    and get `ha-reset` only at a peer's address, on a port of Kea's HA, over
    HTTP/1.0 with a bounded answer;
  - `priority 255` is written as 254 during a maintenance, so that the
    demotion takes;
  - the sysupgrade hook has its own 40-second timer.
- Sync encryption is fail closed. A sync daemon that has work does not
  start without a valid `encryption_key`, and ha-cluster refuses to
  start; plain mode is the explicit `sync_encryption '0'`, never a
  fallback.
- Generated configs live in `/var/run/ha-cluster`, a directory created
  0700 and checked for its owner; files holding keys or passwords are
  created 0600.
- Package-managed dataplane health checks (`check_type 'dataplane'`):
  carrier, optional LACP membership and interface-bound reachability,
  attached to the VRRP instances a check lists.
- IPv6 BACKUP guard: a BACKUP node drops its Router Advertisements and
  incoming DHCPv6 requests, so that clients neither route through it nor
  get addresses from it. With unicast VRRP, which since 2.0.0 keeps both
  families in one instance, the guard follows that instance. It is
  rebuilt after every start and reload, since keepalived reports no state
  for an instance that a reload keeps or removes.
- A node that is stopped but still part of the cluster keeps the guard
  closed. Before, `ha-cluster stop` removed the rules and restarted
  dnsmasq, which then sent Router Advertisements from the node's own
  address: clients routed through a standby. The rules are removed when
  the node leaves the cluster: HA disabled in the config, the service
  disabled, or the package removed.
- The upgrade script puts the guard handler of the installed release
  back after a sysupgrade that kept `/etc/hotplug.d/keepalived/`.
- `dhcp_backend 'kea'`: ISC Kea as the DHCP server of the cluster
  interfaces. lease-sync does not run, the checks that only its dnsmasq
  side needs are skipped, and the guard leaves DHCPv6 to Kea while it keeps
  guarding Router Advertisements. ha-cluster neither runs nor configures
  Kea: its high availability is set up in Kea. See
  [Kea as the DHCP Server](ha-cluster/README.md#kea-as-the-dhcp-server).
- The device of a logical interface is taken from the network config
  while netifd has not brought the interface up. ha-cluster starts at boot
  right after netifd; when it came first, the logical name (`lan`) went
  into the keepalived config in place of the device (`br-lan`), keepalived
  waited for a device of that name, and the node stayed in FAULT until
  ha-cluster was restarted. A config that names devices was not affected.
- With `dhcp_backend 'kea'`, help for Kea's own high availability:
  - a Kea DHCP daemon is told to read its config again when an interface
    has come up on a device it listens on and the device is not the one
    it was. Kea does not notice that netifd made a device anew (`ifdown`
    and `ifup`, a network restart): it goes on running, calls its sockets
    ready and hears nothing, while its partner still reaches it and does
    not take over;
  - the status reports, for each Kea DHCP daemon, whether it is enabled,
    whether its DHCP sockets are open, and the state of its high
    availability, and the cluster is `DEGRADED` when an enabled daemon is
    stopped, not listening on a device of the cluster, alone
    (`partner-down`) or has ended its HA;
  - warnings at start for a Kea config without the high-availability hook,
    for a `"url"` of that hook without a port, with which the two servers
    never find each other, and for a config without socket retries, with
    which a Kea that starts before its interface is up never listens;
  - a `nodes` call that names the nodes alike on every node and gives
    their addresses, for setting up Kea's HA.
- The cluster's own traffic is let through the firewall by ha-cluster:
  rules named `HA-Cluster-...` in `/etc/config/firewall`, visible in LuCI
  like any rule, for VRRP on the devices of the instances and, from the
  addresses of the nodes, for owsync, lease-sync, the listeners of Kea's
  high availability and ping. Every node writes the same rules, so a
  synced firewall config stays right. `firewall '0'` turns this off, and
  `/etc/init.d/ha-cluster firewall` brings the rules up to date without
  touching a daemon. See [Firewall](ha-cluster/README.md#firewall).
- A warning at start for each entry of a sync group that starts with a
  slash: owsync syncs only the files of `/etc/config` and matches entries
  against their names there, so `/etc/config/apcontroller` or
  `/root/.ssh` sync nothing, silently. An entry under `/etc/config` is
  named with what to write instead. Nothing is changed in the config.
- Link-local IPv6 VIPs are written first in an instance: keepalived
  wants the first IPv6 address to be link-local, and warned when the
  sections came in another order.
- `/etc/init.d/ha-cluster start` and `reload` fail when the start fails
  (a config that does not validate); they returned 0 with no daemon
  running, and LuCI's apply reported success.
- A config of the releases before 2.0 found at a start is migrated then,
  with a warning, as the upgrade does, and the guard handlers in
  `/etc/hotplug.d/keepalived/` are brought in line with the release. The
  upgrade migrates once, at the first boot of the image; files put back
  after it (a restored backup, or the kept settings unpacked again because
  a first-boot script rebooted before the boot ended) left the node with
  no file and no lease sync and the status `HEALTHY`. Until the config is
  migrated the status is `DEGRADED` and lists what it found in
  `earlier_model`.
- `dhcp_backend` switches the DHCPv4 server of the cluster interfaces
  between dnsmasq and Kea, and has a third value, `auto`, the new default:
  Kea once its init script starts kea-dhcp4 and kea-dhcp4 listens on a
  cluster interface, dnsmasq otherwise. On the way to Kea the static leases
  of dnsmasq are imported into Kea first (luci-app-kea 0.11.0), the entries
  left are named in the log and the status, dnsmasq's DHCPv4 is switched off
  in the pools of the cluster interfaces (`dhcpv4 'disabled'`, the old value
  kept in `ha_cluster_dhcpv4`), and Kea is restarted (a Kea started while
  dnsmasq held the DHCP port of the interface could not bind its fallback
  socket); if it does not run and
  listen within ten seconds everything is put back and the status says
  why. With `kea` and `dnsmasq` ha-cluster also turns kea-dhcp4 on or off in
  `/etc/config/kea`. A switch is refused, before anything changes, when Kea
  does not listen on a cluster interface, has no subnet for it, or dnsmasq
  gives out DHCPv6 there. The node keeps the server it runs in
  `/etc/ha-cluster/dhcp-backend`; a node that never switched runs Kea only
  with `dhcp_backend 'kea'`, as before. luci-app-kea's `kea.service` event
  makes a running cluster check its server (`/etc/init.d/ha-cluster
  kea_changed`). Before, `kea` only told ha-cluster that Kea was the server,
  and the pools and Kea were the user's to switch. The status gives
  `dhcp_backend` (the server the node runs), `dhcp_backend_mode`,
  `dhcp_backend_problem` and `kea_import`, and is `DEGRADED` when the pools
  say otherwise than the node's server (another node switched alone, or
  two servers on a cluster interface).
- Whether a Kea DHCP daemon listens on a device is read from its
  `interfaces-config` when the config is plain JSON; a device named only in
  a subnet no longer counts.
- What ha-cluster writes to `/etc/config/firewall`, `/etc/config/dhcp` and
  `/etc/config/kea` no longer takes along what a user has staged in LuCI
  and not applied. It went through `uci -t <own save directory>`, but uci
  applies the pending changes of `/tmp/.uci` with any save directory: the
  commit wrote the user's staged changes into the file, and left them
  staged besides (CA-HACLUSTER-02 of the w0w6 audit; the firewall rules
  have had it since they came). The changes are now made on a copy of the
  committed file under another package name, which replaces the file under
  its lock, as uci does, and only when the file did not change meanwhile.
- The switch of the DHCP server takes its lock for the whole run. BusyBox's
  flock has no `-w`: the lock was never taken. A switch to Kea is noted
  (`switching`) before the pools change, and one cut short by a reboot or
  a kill is made again or undone at the next start; with `auto`, a Kea
  that still runs and serves a cluster interface when the node goes back
  to dnsmasq is restarted and, if it still serves it, stopped, so that one
  DHCP server answers (CA-HACLUSTER-03).
- The rule of Kea's high availability no longer opens a port below 1024 or
  the port of owsync or lease-sync, which a `"url"` in Kea's config may
  name (a user of luci-app-kea may not be one who may open the firewall);
  a warning names them (CA-LUCIKEA-02).
- The run directory is made root's (0700) also by what runs before the
  service, and a stale IPv6 guard handler shows in the status
  (CA-HACLUSTER-05); the entries an import leaves are logged without word
  splitting or eval (CA-HACLUSTER-04).
- The switch of the DHCP server finds the pools of a VIP whose `interface`
  names a device (`br-lan`, `bond0.87`) rather than the logical interface:
  through the network config, the logical interfaces whose device it is.
  Before, such a pool was left giving out DHCPv4 beside Kea, the status
  did not see it, and Kea could not bind its fallback socket there (found
  on the bench with the routers' config, r17).
- The ports of Kea's high availability are dropped from anybody but the
  nodes (`HA-Cluster-Kea-HA-drop`, right after the rule that accepts them).
  Kea's listener takes commands without authentication (its basic-auth is
  not checked there in Kea 3.0.4, only mutual TLS is), and a zone with
  input `ACCEPT`, such as `lan` with the sync link in it, let any of its
  clients reach it at a node's sync address: on the bench a LAN client got
  an answer from Kea. Before, only the accepting rule was written (r18).
- A switch to Kea sets Kea up when Kea's config is all it lacks and that
  config is still the sample of the Kea package: luci-app-kea's
  `setup-from-dnsmasq` (0.15.0) writes it from dnsmasq's pools and the nodes
  of the cluster, Kea is checked again, and once Kea serves, dnsmasq's
  active leases are handed to it (`import-dnsmasq --leases`, from a copy
  of dnsmasq's lease file taken before the pools changed). A config of
  the user's own is never touched, and the refusal says so. Before, Kea had
  to be set up by hand first, which a router left with the package's sample
  showed (r19).
- `nodes` is made by ha-cluster itself (`ha_nodes_json`), also for the
  switch, and lists the cluster's DHCP interfaces with their devices and
  the IPv4 addresses of their VIPs (`dhcp_interfaces`).
- A VIP whose `interface` is neither a logical interface nor the device of
  one is taken as it is again, as before r17.
- The README says what IPv6 does with Kea ("IPv6 with Kea: Router
  Advertisements and DHCPv6"): the switch moves DHCPv4 only, the Router
  Advertisements stay with dnsmasq, why Kea sends none, and what DHCPv6
  from Kea would need in a cluster.
- With `dhcp_backend 'auto'` the pair switches together: a node follows a
  switch of the DHCP server made on the other node, as the synced pools
  tell it, to Kea and back, and turns off again what it turned on in Kea's
  settings to follow (`/etc/ha-cluster/kea-followed`). It changes no pool,
  and does not follow while its own switch was cut short, Kea was stopped
  on it on purpose, or kea-dhcp4 is missing. Kea's high availability wants
  Kea on both servers; before, the second node stayed on dnsmasq, and with
  the pools off it gave out no DHCPv4 until it was switched by hand
  (`/etc/init.d/ha-cluster dhcp_changed`, run by procd when
  `/etc/config/dhcp` changed) (r20).
- Files a peer sends are applied: owsync runs
  `/usr/lib/ha-cluster/owsync-changed` after a session that changed files
  (`on_change`), which runs `reload_config` once for a burst of sessions.
  Before, a synced DHCP pool or firewall rule stayed out of the peer's
  running service until something else reloaded it (r20).
- A warning at start when kea-dhcp4 listens on a cluster device with a VIP
  without an address (or on "*"): Kea then opens a socket for each IPv4
  address of the device and takes, and answers, each request once per
  address. It names the entry to write, the device with this node's own
  address on it (found by the luci-app-kea session in Kea 3.0.4's
  cfg_iface.cc, measured three times over with three addresses).

### luci-app-ha-cluster
- Advanced WAN page for the uplink sections, with a description under
  every option and a warning about keepalived handlers of the user's that
  bring interfaces up or down. The Status page lists the uplinks, shows a
  maintenance of the node or of its peer, and has the maintenance
  buttons; the `maintenance` call (write ACL) runs the command in the
  background and refuses at once while the peer could not take over,
  unless forced. Needs ha-cluster 2.0.0-r21 or later (r14).
- r16: the page is called Advanced Multi-WAN Management and lists every WAN
  interface (mwan3's, and those of the firewall zones that masquerade) as
  Unmanaged; mode and VRRP instance are chosen in the table, the other
  settings in the edit dialog, and Add picks another interface from a list.
  Reads the firewall and mwan3 configs (read ACL). Needs ha-cluster
  2.0.0-r24.
- r15: the maintenance buttons are greyed while a command runs
  (`maintenance_running`), the `maintenance` call refuses a second command
  at once, and Advanced WAN refuses a Master only uplink on an interface the
  cluster runs on. Needs ha-cluster 2.0.0-r23.
- The `nodes` call answers with ha-cluster's `ha_nodes_json`, which adds
  `dhcp_interfaces`; it needs ha-cluster 2.0.0-r19 (r13).
- "Encrypt Sync Traffic" switch on the General page, for the backend's
  `sync_encryption`.
- Dataplane health checks on the Keepalived (Advanced) page.
- The peer address is passed to ping after `--`.
- "DHCP Server" on the General page, for `dhcp_backend`; with Kea the
  Status page lists the Kea DHCP daemons, with what each says about its
  sockets and its high availability.
- "Firewall Rules" on the General page, for `firewall`.
- The help of a sync group's files no longer offers absolute paths,
  which owsync never syncs.
- Removing a VRRP instance on the Advanced VRRP page takes it out of the
  health checks that track it, and is refused while a dataplane check
  tracks nothing else; removing a health check takes it out of the
  instances' Track Scripts. A name left behind failed the backend's
  validation, and the cluster did not start.
- The Status page says when `/etc/config/ha-cluster` is still in the form
  of the releases before 2.0 (`earlier_model` of the status).
- "DHCP Server" on the General page offers Automatic, the default; the
  Status page shows the server the node runs, why a switch was not made,
  and the static leases of dnsmasq the import left for luci-app-kea.
- The status lists an IPv6 guard handler of an earlier release under
  `earlier_model`, and reads the import's leftovers without eval.
- r18: the hook editor sets the script as the value of its text field.
  As a child of the element it was read as HTML, and an `&amp;` or `&lt;`
  of a script came back as `&` or `<` at the next save. The remaining
  messages and status cells built from data (hook names, error texts,
  states, the generated key) go in as text.

### kea-dnsmasq-hosts (new, 1.0.0-r5)
- The names of Kea's DHCP clients in dnsmasq's DNS, which takes no DDNS
  updates: a service rebuilds `/tmp/hosts/kea-leases` from the lease files
  of the Kea DHCP daemons that run on the node, when Kea's run script hook
  says leases changed (at most every five seconds) and every minute, and
  sends dnsmasq SIGHUP when it changed. In a Kea HA pair each node's lease
  files hold its partner's leases too, so every node answers for every
  name. Needs `kea-hook-run-script`, which OpenWrt's Kea package does not
  build; the hook is set in Kea's config (luci-app-kea's "Client names in
  DNS"). Independent of ha-cluster.
- Only the first label of a client's name is published, and never a name
  of `/etc/hosts`, of a static lease, the router's own name, `wpad`,
  `isatap` or `localhost`; of two clients with one name the first keeps
  it. A client could make the router answer for any name of any domain
  (CA-KEAHOSTS-01). The hosts file is written through `mktemp`, the lease
  files are passed quoted and absolute, and the hook writes nothing through
  a link (CA-KEAHOSTS-02).
- The name of a static lease of `/etc/config/dhcp` is published for that
  host's own lease from Kea (its MAC or its address), as dnsmasq did with
  its own DHCP; before, every static lease name was withheld, and a host
  whose static lease was imported into Kea had no name in DNS. Other
  clients still cannot take it, and a `domain` name stays taken (found on
  the bench, r4).
- r5: the service removes its hosts file only when two looks ten seconds
  apart find no Kea DHCP server. A look that fell into the second or two
  of a restart of Kea took every client name out of DNS for a minute.

### lease-sync, owsync, dnsmasq-ha
- dnsmasq-ha r5: the two patches OpenWrt carries for dnsmasq 2.93 since
  2026-11 (`001-fix_severe_SIGHUP_reload_slowdown`,
  `002-tune-store_name-fix-in-47864f3`): a reload on SIGHUP with large
  hosts files no longer slows down with every reload.
- lease-sync: DHCPv6 leases identified by DUID and IAID, the echo of a
  deletion asked of dnsmasq suppressed, peers checked before a message
  is used.
  A DHCPv6 renewal served by a node after a failover, or after its
  lease-sync restarted, is taken over and sent to the peer; before, it
  was dropped as the echo of a peer's lease, and the lease was lost when
  the other copy ran out.
  No echo is expected after a lease is injected: dnsmasq-ha runs no
  script for it, and waiting for one dropped the next real event for
  that address within ten seconds.
- owsync: connections accepted from the configured peers only, a cap on
  the frame size before the handshake, peer file states validated, and a
  fix for the crash when a tombstone expires. `on_change` (r6): a program
  run, without a shell and detached, after a sync session wrote or removed
  local files.
- dnsmasq-ha: DHCPv6 leases carry the client DUID over ubus; the
  dhcp-script forwards only `NAME=value` lines to hotplug. The log line
  of an injected DHCPv6 lease shows the whole client id; it showed its
  first byte.

### Tests
- The rootless characterization run no longer depends on what the rootfs
  holds of keepalived-sync: its hooks are removed from the test root, and
  the cases about them write their own. The init script is bound with the
  mode the package installs (0755); case 168 runs the sysupgrade hook.
- `tests/unit`: host-side tests, no container needed.
- `tests/scripts/run-characterization-rootless.sh`: the T24 cases
  without podman or docker, in a bubblewrap sandbox over an unpacked
  OpenWrt rootfs. The expected outputs are the fork's; cases for the
  fork's own behaviour are added.
- T28, the DHCPv6 BACKUP guard scenario.
- `tests/unit/test-kea-dnsmasq-hosts.sh`: the hosts file of kea-dnsmasq-hosts
  from Kea's lease files.

## [2.0.0] - 2026-10-24

Before upgrading from 1.0.x, read
[Upgrading from 1.0.x to 2.0.0](ha-cluster/README.md#upgrading): the
configuration is migrated in place, and all nodes must be upgraded
together, BACKUP nodes first: the upgrade restarts keepalived once.

Builds for OpenWrt 25.12 should use the feed's new `openwrt-25.12`
branch: `master` now follows OpenWrt `main` (see
[Add the Feed](README.md#add-the-feed)).

| Package | 1.0.0 | 2.0.0 |
|---------|-------|-------|
| `ha-cluster` | 1.0.0 | 2.0.0 |
| `luci-app-ha-cluster` | 1.0.0 | 2.0.0 |
| `lease-sync` | 1.0.0 | 1.2.1 ([changelog](https://github.com/pgaufillet/lease-sync/blob/v1.2.1/CHANGELOG.md)) |
| `owsync` | 1.2.0 | 1.3.0 ([changelog](https://github.com/pgaufillet/owsync/blob/v1.3.0/CHANGELOG.md)) |
| `dnsmasq-ha` | 2.90 | 2.93 |

### Platform
- Feed branches: `master` follows OpenWrt `main`, `openwrt-25.12` follows
  OpenWrt 25.12.
- OpenWrt 25.12 and its apk package manager. OpenWrt 24.10 (opkg) is no
  longer supported.
- Docker build environment based on the OpenWrt SDK, for any target and
  stable release, with parallel and incremental builds.
- The feed can be hosted as a signed apk repository (key generation in
  the README).
- `scripts/install-ha-cluster.sh` installs the cluster on a router and
  swaps dnsmasq for dnsmasq-ha once every dependency is in place. It no
  longer installs `kmod-ipt-ipset`.

### dnsmasq-ha
- Updated to dnsmasq 2.93: fixes CVE-2026-2291, CVE-2026-4890,
  CVE-2026-4891, CVE-2026-4892, CVE-2026-4893 and CVE-2026-5172.
- Follows the stock OpenWrt 25.12 dnsmasq package: same `files/` and
  patches, built with the dnsmasq-full default options (nftset, no ipset,
  TFTP).
- ubus lease methods: fixed an out-of-bounds write in the `get_leases`
  MAC formatting, hardened input handling, and `add_lease` rejects an
  `is_temporary` mismatch.

### ha-cluster
Configuration (breaking, migrated on upgrade except the first item):
- VRRP settings move to `vrrp_instance` sections; each VIP names its
  instance, and the VIPs of an instance fail over together. A
  configuration from the 1.0.0 tag, with `vrid` and `priority` on each
  VIP, is not converted: recreate its VIPs after upgrading.
- `service` sections become `sync_group` sections.
- Lease sync has its own global switch, `lease_sync`, instead of the DHCP
  group's `sync_leases`.
- Peer `sync_enabled '0'` becomes `vrrp_only '1'`.
- Removed: the wireless sync group, `sync_method`,
  `lease_sync_persist_interval`.

Behaviour:
- A VIP without an `enabled` option is enabled, as LuCI shows it.
- owsync and lease-sync are optional: each runs only when installed and
  needed. A daemon that is needed but not installed is logged as a
  warning.
- With unicast peers, an IPv6-only instance runs as `<name>` with its own
  VRID (no longer `<name>_v6` with VRID+128); with IPv6 unicast peers and
  IPv4 VIPs only, the instance advertises no address. Unicast VRRP keeps
  one address family per instance.
- A warning when dnsmasq is authoritative while leases or the DHCP
  configuration are synced.
- keepalived is reloaded on a configuration change, dnsmasq is restarted
  only when its overlay changed, and package upgrades keep the boot state.
- The generated `keepalived.conf` is created with mode 0600.

### luci-app-ha-cluster
- Pages follow the new configuration model: VRRP instances, VIPs per
  instance (IPv4 and IPv6), sync groups.
- Status page: role per VRRP instance, the daemons the configuration
  needs, and a retried keepalived dump (the role is no longer shown as
  UNKNOWN after an empty dump).
- Layout for phones, theme fixes, no default values written to the
  configuration, corrected unicast help texts.

### lease-sync package
- The standalone init script passes the security options to the daemon
  and keeps the boot state across upgrades.

### Documentation
- Package links in the README and a dnsmasq-ha README.
- Upgrade notes, attended sysupgrade, DHCP prerequisites, and the known
  limits (one dnsmasq section, unicast derivation).

## [1.0.0] - 2026-03-02

Initial release, for OpenWrt 24.10: `ha-cluster` 1.0.0,
`luci-app-ha-cluster` 1.0.0, `lease-sync` 1.0.0, `owsync` 1.2.0,
`dnsmasq-ha` 2.90.
