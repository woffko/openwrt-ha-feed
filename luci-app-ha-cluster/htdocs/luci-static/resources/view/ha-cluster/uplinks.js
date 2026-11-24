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

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('ha-cluster'),
			uci.load('network'),
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
		var foreignHooks = data[2] || [];
		var m, s, o;

		m = new form.Map('ha-cluster', _('High Availability - Advanced WAN'),
			_('Uplinks follow this node\'s VRRP role. A "Master only" uplink is up only while this node is MASTER of the chosen VRRP instance, so a login that allows one session is never dialed by both nodes. An uplink never changes the role: a MASTER whose uplink fails stays MASTER and the cluster status shows DEGRADED.'));

		if (foreignHooks.length) {
			s = m.section(form.NamedSection, 'config', 'global');
			s.render = function() {
				return E('div', { 'class': 'alert-message warning' }, [
					E('p', {}, _('These handlers in %s also bring interfaces up or down at VRRP changes: %s. Remove a handler once an uplink below manages its interface, or both act on it.')
						.format(HOOK_DIR, foreignHooks.join(', ')))
				]);
			};
		}

		s = m.section(form.GridSection, 'uplink', _('Uplinks'),
			_('Each uplink names one interface of Network → Interfaces. The IPv6 alias of an interface (for example wan_6) follows it. Routes between several uplinks stay with mwan3.'));
		s.addremove = true;
		s.anonymous = false;
		// The descriptions are shown under each field of the edit dialog;
		// in the table of named sections LuCI puts them one column off
		s.nodescriptions = true;
		s.modaltitle = function(section_id) {
			return _('Uplink') + ' » ' + section_id;
		};

		o = s.option(form.Flag, 'enabled', _('Enabled'),
			_('Manage this interface. When disabled, ha-cluster leaves the interface alone and restores its "Bring up on boot" setting.'));
		o.default = '1';
		o.rmempty = false;
		o.editable = true;

		o = s.option(widgets.NetworkSelect, 'interface', _('Interface'),
			_('Logical network interface: PPPoE, DHCP, static, LTE. Its IPv6 alias (for example wan_6) follows it. In Master only mode ha-cluster turns "Bring up on boot" off for this interface and keeps the previous value, which it restores when the uplink is disabled or removed or the cluster is turned off.'));
		o.nocreate = true;
		o.rmempty = false;
		o.exclude = 'loopback';

		o = s.option(form.ListValue, 'mode', _('Mode'),
			_('Master only: up only on the MASTER of the VRRP instance below; for a line or a login that allows one session. Always: up on every node whatever the role; ha-cluster only watches it and warns when the backup node\'s uplink is down, since a failover would then leave the new MASTER without it.'));
		o.value('master', _('Master only'));
		o.value('always', _('Always'));
		o.default = 'master';
		o.textvalue = function(section_id) {
			return (this.cfgvalue(section_id) || this.default) === 'always' ? _('Always') : _('Master only');
		};

		o = s.option(form.ListValue, 'vrrp_instance', _('VRRP instance'),
			_('Whose role the uplink follows. Usually the LAN instance: the node that holds the gateway address goes online. Not used in Always mode.'));
		o.value('', _('none'));
		uci.sections('ha-cluster', 'vrrp_instance').forEach(function(section) {
			o.value(section['.name'], section['.name'] + (section.interface ? ' (' + section.interface + ')' : ''));
		});
		o.validate = function(section_id, value) {
			var mode = this.section.formvalue(section_id, 'mode');
			if (mode != 'always' && !value)
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
