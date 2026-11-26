/*
 * SPDX-License-Identifier: Apache-2.0
 */
'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require tools.widgets as widgets';

var HOOK_DIR = '/etc/hotplug.d/keepalived';
var OWN_HOOKS = /-(ha-cluster-role|ipv6-backup-guard)$/;
var PPP_PROTOS = [ 'pppoe', 'pppoa', 'ppp' ];

// The logical interfaces the cluster runs on, as ha-cluster's validation
// finds them: loopback, those of the VRRP instances and VIPs (named, or
// holding the addresses of the device they name), and those carrying
// bind_address or a peer's source_address. A Master only uplink there
// would go down on the BACKUP.
function clusterInterfaces() {
	var own = { loopback: true };
	var ifaces = uci.sections('network', 'interface');
	var addresses = {};

	var add = function(name) {
		if (!name)
			return;
		if (ifaces.some(function(i) { return i['.name'] == name; })) {
			own[name] = true;
			return;
		}
		// A device: the interfaces that hold its addresses; a PPP session
		// on it has a device of its own and leaves it up when it goes
		ifaces.forEach(function(i) {
			if (i.device == name && PPP_PROTOS.indexOf(i.proto) < 0)
				own[i['.name']] = true;
		});
	};

	uci.sections('ha-cluster', 'vrrp_instance').forEach(function(s) { add(s.interface); });
	uci.sections('ha-cluster', 'vip').forEach(function(s) { add(s.interface); });

	var bind = uci.get('ha-cluster', 'config', 'bind_address');
	if (bind)
		addresses[bind] = true;
	uci.sections('ha-cluster', 'peer').forEach(function(s) {
		if (s.source_address)
			addresses[s.source_address] = true;
	});
	ifaces.forEach(function(i) {
		if (i.device == 'lo')
			own[i['.name']] = true;
		L.toArray(i.ipaddr).forEach(function(a) {
			if (addresses[String(a).split('/')[0]])
				own[i['.name']] = true;
		});
	});
	return own;
}

// The WAN interfaces the page lists by default: those of mwan3 and those of
// the firewall zones that masquerade, in the order of the network config.
// Left out: loopback, and an interface on the device of another one's
// session or an alias of it (wan_6 on pppoe-wan, @wan), which follows it.
function wanInterfaces() {
	var ifaces = uci.sections('network', 'interface');
	var wanted = {};

	var known = function(name) {
		return ifaces.some(function(i) { return i['.name'] == name; });
	};
	(uci.sections('mwan3', 'interface') || []).forEach(function(s) {
		if (known(s['.name']))
			wanted[s['.name']] = true;
	});
	uci.sections('firewall', 'zone').forEach(function(z) {
		if (z.masq != '1')
			return;
		L.toArray(z.network).forEach(function(name) {
			if (known(name))
				wanted[name] = true;
		});
	});

	var follows = function(i) {
		var dev = i.device || '';
		if (dev.charAt(0) == '@')
			return true;
		return ifaces.some(function(o) {
			return PPP_PROTOS.indexOf(o.proto) >= 0 && dev == o.proto + '-' + o['.name'];
		});
	};

	return ifaces.filter(function(i) {
		return wanted[i['.name']] && i['.name'] != 'loopback' && !follows(i);
	}).map(function(i) { return i['.name']; });
}

// The VRRP instance a new uplink follows by default: the one on the LAN
function defaultInstance() {
	var instances = uci.sections('ha-cluster', 'vrrp_instance');
	var lan = instances.filter(function(s) {
		return s.interface == 'lan' || s.interface == uci.get('network', 'lan', 'device');
	});
	var pick = lan.length ? lan[0] : instances[0];
	return pick ? pick['.name'] : null;
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('ha-cluster'),
			uci.load('network'),
			L.resolveDefault(uci.load('firewall'), null),
			L.resolveDefault(uci.load('mwan3'), null),
			// The user's own handlers that bring interfaces up or down at
			// VRRP changes, besides ha-cluster's
			L.resolveDefault(fs.list(HOOK_DIR), []).then(function(entries) {
				return Promise.all(entries.filter(function(e) {
					return e.type == 'file' && !OWN_HOOKS.test(e.name);
				}).map(function(e) {
					return L.resolveDefault(fs.read(HOOK_DIR + '/' + e.name), '').then(function(text) {
						return /(^|[^A-Za-z0-9_-])(ifup|ifdown)([^A-Za-z0-9_-]|$)|network\.interface/.test(text || '') ? e.name : null;
					});
				}));
			}).then(function(names) {
				return names.filter(function(n) { return n != null; });
			})
		]);
	},

	render: function(data) {
		var foreignHooks = data[4] || [];
		var m, s, o;

		// Every WAN interface is listed, Unmanaged unless it has an uplink
		// section: those it lacks are added here, and reach the config
		// only when the page is saved
		var listed = {};
		uci.sections('ha-cluster', 'uplink').forEach(function(u) {
			if (u.interface)
				listed[u.interface] = true;
		});
		var instance = defaultInstance();
		wanInterfaces().forEach(function(name) {
			if (listed[name])
				return;
			var sid = uci.add('ha-cluster', 'uplink',
				/^[A-Za-z0-9_]+$/.test(name) && !uci.get('ha-cluster', name) ? name : null);
			uci.set('ha-cluster', sid, 'interface', name);
			uci.set('ha-cluster', sid, 'mode', 'unmanaged');
			if (instance)
				uci.set('ha-cluster', sid, 'vrrp_instance', instance);
		});

		m = new form.Map('ha-cluster', _('High Availability - Advanced Multi-WAN Management'),
			_('Uplinks follow this node\'s VRRP role. A "Master only" uplink is up only while this node is MASTER of the chosen VRRP instance, so a login that allows one session is never dialed by both nodes. An uplink never changes the role: a MASTER whose uplink fails stays MASTER and the cluster status shows DEGRADED.'));

		if (foreignHooks.length) {
			s = m.section(form.NamedSection, 'config', 'global');
			s.render = function() {
				return E('div', { 'class': 'alert-message warning' }, [
					E('p', {}, [ _('These handlers in %s also bring interfaces up or down at VRRP changes: %s. Remove a handler once an uplink below manages its interface, or both act on it.')
						.format(HOOK_DIR, foreignHooks.join(', ')) ])
				]);
			};
		}

		s = m.section(form.GridSection, 'uplink', _('Uplinks'),
			_('Every WAN interface is listed: those of mwan3 and of the firewall zones that masquerade, Unmanaged until a mode is chosen. An IPv6 interface on the device of another one\'s session (wan_6 on pppoe-wan) follows it and is not listed. Add lists another interface. Routes between several uplinks stay with mwan3.'));
		s.addremove = true;
		s.anonymous = true;
		// The descriptions are shown under each field of the edit dialog
		s.nodescriptions = true;
		s.modaltitle = function(section_id) {
			return _('Uplink') + ' » ' + (uci.get('ha-cluster', section_id, 'interface') || _('new'));
		};

		o = s.option(widgets.NetworkSelect, 'interface', _('Interface'),
			_('Logical network interface: PPPoE, DHCP, static, LTE. An IPv6 interface on the device of its session (wan_6 on pppoe-wan) follows it. In Master only mode ha-cluster turns "Bring up on boot" off for this interface and keeps the previous value, which it restores when the uplink goes back to Unmanaged, is removed, or the cluster is turned off.'));
		o.nocreate = true;
		o.rmempty = false;
		o.exclude = 'loopback';

		o = s.option(form.ListValue, 'mode', _('Mode'),
			_('Unmanaged: ha-cluster leaves the interface alone. Master only: up only on the MASTER of the VRRP instance; for a line or a login that allows one session. Always: up on every node whatever the role; ha-cluster only watches it and warns when the backup node\'s uplink is down, since a failover would then leave the new MASTER without it.'));
		o.value('unmanaged', _('Unmanaged'));
		o.value('master', _('Master only'));
		o.value('always', _('Always'));
		o.default = 'unmanaged';
		o.rmempty = false;
		o.editable = true;
		o.validate = function(section_id, value) {
			var iface = this.section.formvalue(section_id, 'interface') ||
				uci.get('ha-cluster', section_id, 'interface');
			if (value == 'master' && iface && clusterInterfaces()[iface])
				return _('The cluster runs on this interface (a VRRP instance, a VIP or the sync link): in Master only mode it would go down on the backup node and stay down at boot');
			return true;
		};

		o = s.option(form.ListValue, 'vrrp_instance', _('VRRP instance'),
			_('Whose role the uplink follows. Usually the LAN instance: the node that holds the gateway address goes online. Not used in Always mode.'));
		o.value('', _('none'));
		uci.sections('ha-cluster', 'vrrp_instance').forEach(function(section) {
			o.value(section['.name'], section['.name'] + (section.interface ? ' (' + section.interface + ')' : ''));
		});
		o.editable = true;
		o.validate = function(section_id, value) {
			var mode = this.section.formvalue(section_id, 'mode');
			if (mode == 'master' && !value)
				return _('A Master only uplink needs a VRRP instance');
			return true;
		};

		o = s.option(form.Value, 'up_delay', _('Up delay, s'),
			_('Wait this long after becoming MASTER before bringing the interface up. 0 brings it up at once. Use 5-10 s if the VRRP role flaps, so that a node that is MASTER only briefly does not dial.'));
		o.datatype = 'range(0,3600)';
		o.placeholder = '0';
		o.modalonly = true;

		o = s.option(form.Value, 'grace', _('Grace period, s'),
			_('How long a MASTER may stay without a working uplink before the cluster status turns DEGRADED. Only a signal: nothing is restarted. After an unplanned failover the provider may hold the old session for minutes.'));
		o.datatype = 'range(0,86400)';
		o.placeholder = '180';
		o.modalonly = true;

		o = s.option(form.Value, 'retry', _('Retry interval, s'),
			_('Interval of ha-cluster\'s own reconnect attempts while netifd has stopped retrying, for example after an authentication failure on an interface with "authfail" set. Not used while netifd retries by itself. Configuration errors are not retried.'));
		o.datatype = 'range(5,3600)';
		o.placeholder = '30';
		o.modalonly = true;

		return m.render();
	}
});
