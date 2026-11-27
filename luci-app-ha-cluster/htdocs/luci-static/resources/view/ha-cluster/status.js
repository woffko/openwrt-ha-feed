/*
 * Copyright (c) 2025-2026 Pierre Gaufillet <pierre.gaufillet@bergamote.eu>
 * SPDX-License-Identifier: Apache-2.0
 */
'use strict';
'require view';
'require poll';
'require rpc';
'require dom';
'require ui';
'require fs';

var callHAClusterStatus = rpc.declare({
	object: 'ha-cluster',
	method: 'status',
	expect: { }
});

var callMaintenance = rpc.declare({
	object: 'ha-cluster',
	method: 'maintenance',
	params: [ 'action', 'force' ],
	expect: { }
});

return view.extend({
	__init__: function() {
		this.super('__init__', arguments);
		this.pollData = null;
	},

	load: function() {
		return Promise.all([
			this.loadData(),
			L.resolveDefault(fs.stat('/usr/bin/owsync'), null),
			L.resolveDefault(fs.stat('/usr/sbin/lease-sync'), null)
		]);
	},

	loadData: function() {
		return callHAClusterStatus().catch(function(err) {
			console.error('ha-cluster status RPC failed:', err);
			return {};
		});
	},

	formatUptime: function(seconds) {
		if (!seconds) return '-';
		var days = Math.floor(seconds / 86400);
		var hours = Math.floor((seconds % 86400) / 3600);
		var mins = Math.floor((seconds % 3600) / 60);

		var parts = [];
		if (days > 0) parts.push(days + 'd');
		if (hours > 0) parts.push(hours + 'h');
		if (mins > 0 || parts.length === 0) parts.push(mins + 'm');

		return parts.join(' ');
	},

	formatRelativeTime: function(unixTimestamp) {
		if (!unixTimestamp || unixTimestamp === 0) {
			return _('Never');
		}

		var now = Math.floor(Date.now() / 1000);
		var diff = now - unixTimestamp;

		if (diff < 60) {
			return _('Just now');
		} else if (diff < 3600) {
			var mins = Math.floor(diff / 60);
			return mins + ' ' + (mins === 1 ? _('minute ago') : _('minutes ago'));
		} else if (diff < 86400) {
			var hours = Math.floor(diff / 3600);
			return hours + ' ' + (hours === 1 ? _('hour ago') : _('hours ago'));
		} else {
			var days = Math.floor(diff / 86400);
			return days + ' ' + (days === 1 ? _('day ago') : _('days ago'));
		}
	},

	// Missing package that the configuration asks for
	isMissing: function(serviceInfo, installed) {
		return !installed && !!(serviceInfo && serviceInfo.wanted);
	},

	renderServiceRow: function(name, serviceInfo, installed) {
		var isRunning = (serviceInfo && serviceInfo.running) || false;
		var isRequired = (serviceInfo && serviceInfo.required) || false;
		var pid = (serviceInfo && serviceInfo.pid) || '-';
		var uptime = (serviceInfo && this.formatUptime(serviceInfo.uptime)) || '-';

		var statusBadge;
		if (isRunning) {
			statusBadge = E('span', { 'class': 'label success' }, _('Running'));
		} else if (isRequired) {
			statusBadge = E('span', { 'class': 'label important' }, _('Stopped'));
		} else if (this.isMissing(serviceInfo, installed)) {
			statusBadge = E('span', { 'class': 'label' }, _('Not installed'));
		} else {
			statusBadge = E('span', { 'class': 'label' }, _('Disabled'));
		}

		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'data-title': _('Service') }, name),
			E('td', { 'class': 'td left', 'data-title': _('Status') }, statusBadge),
			E('td', { 'class': 'td left', 'data-title': _('PID') }, [ String(pid) ]),
			E('td', { 'class': 'td left', 'data-title': _('Uptime') }, [ uptime ])
		]);
	},

	// A Kea daemon: ha-cluster does not run it, the row says what it finds
	renderKeaRow: function(name, serviceInfo) {
		var isRunning = (serviceInfo && serviceInfo.running) || false;
		var isInstalled = (serviceInfo && serviceInfo.installed) || false;
		var pid = (isRunning && serviceInfo.pid) || '-';
		var uptime = (isRunning && this.formatUptime(serviceInfo.uptime)) || '-';

		var problem = (serviceInfo && serviceInfo.problem) || '';
		var ha = (serviceInfo && serviceInfo.ha) || null;

		var statusBadge;
		if (isRunning)
			statusBadge = E('span', { 'class': 'label success' }, _('Running'));
		else if (problem === 'stopped')
			// Enabled in Kea's own config, so the cluster has no DHCP here
			statusBadge = E('span', { 'class': 'label important' }, _('Stopped'));
		else if (isInstalled)
			statusBadge = E('span', { 'class': 'label' }, _('Stopped'));
		else
			statusBadge = E('span', { 'class': 'label' }, _('Not installed'));

		// What a running Kea says about itself: whether it listens, and
		// where its own high availability stands. Nothing is added when it
		// could not be asked.
		var status = [ statusBadge ];
		var problems = {
			'not-listening': _('Not listening'),
			'ha-terminated': _('Kea HA terminated'),
			'partner-down': _('Partner down')
		};

		// The reason Kea gives for sockets that are not open is the tooltip
		if (isRunning && problems[problem])
			status.push(' ', E('span', {
				'class': 'label important',
				'title': (problem === 'not-listening' && serviceInfo.sockets_error) || null
			}, problems[problem]));

		if (isRunning && ha) {
			var text = _('Kea HA: %s (%s)').format(ha.state || '?', ha.role || '?');
			if (ha.partner_in_touch === false)
				text += ', ' + _('partner not in touch');
			status.push(' ', E('span', {}, [ text ]));
		} else if (isRunning && serviceInfo.sockets) {
			status.push(' ', E('span', {}, _('No Kea HA')));
		}

		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'data-title': _('Service') }, name),
			E('td', { 'class': 'td left', 'data-title': _('Status') }, status),
			E('td', { 'class': 'td left', 'data-title': _('PID') }, [ String(pid) ]),
			E('td', { 'class': 'td left', 'data-title': _('Uptime') }, [ uptime ])
		]);
	},

	formatLastSync: function(serviceInfo, installed, timestamp) {
		if (serviceInfo && serviceInfo.required)
			return this.formatRelativeTime(timestamp);
		if (this.isMissing(serviceInfo, installed))
			return _('Not installed');
		return _('Disabled');
	},

	renderStatus: function(data, owsyncInstalled, leaseSyncInstalled) {
		var status = data || {};
		var services = status.services || {};
		// Kea replicates its leases itself and lease-sync does not run
		var keaBackend = status.dhcp_backend === 'kea';

		var clusterState = status.state || 'UNKNOWN';
		var nodeRole = status.role || 'UNKNOWN';
		var peers = status.peers || [];
		var syncStatus = status.sync || {};

		var stateClass;
		switch (clusterState) {
			case 'HEALTHY':
				stateClass = 'label success';
				break;
			case 'DEGRADED':
				stateClass = 'label warning';
				break;
			case 'FAULTY':
				stateClass = 'label important';
				break;
			case 'MAINTENANCE':
				stateClass = 'label notice';
				break;
			default:
				stateClass = 'label';
		}

		var roleClass;
		switch (nodeRole) {
			case 'MASTER':
				roleClass = 'label success';
				break;
			case 'BACKUP':
				roleClass = 'label notice';
				break;
			case 'FAULT':
				roleClass = 'label important';
				break;
			case 'MIXED':
				roleClass = 'label warning';
				break;
			default:
				roleClass = 'label';
		}

		var instances = status.instances || {};
		var instanceNames = Object.keys(instances);

		// What the config holds of the releases before 2.0: the service
		// migrates it when it starts, so this shows only until then, or when
		// that failed
		var earlierModel = Array.isArray(status.earlier_model) ? status.earlier_model : [];
		var earlierWarning = earlierModel.length > 0 ? [
			E('div', { 'class': 'alert-message warning' }, [
				_('/etc/config/ha-cluster is in the form of the releases before 2.0 (%s), which this release does not read: configuration and leases are not synchronized. Restarting the HA cluster service migrates it, as the upgrade does; the system log says why if it does not.')
					.format(earlierModel.join(', ')) ])
		] : [];

		// The DHCP server of the cluster interfaces: why the one asked for is
		// not in use, and the static leases of dnsmasq not taken into Kea
		var dhcpMode = status.dhcp_backend_mode || 'auto';
		var dhcpServer = (status.dhcp_backend === 'kea') ? 'Kea' : 'dnsmasq';
		if (dhcpMode === 'auto')
			dhcpServer = _('%s (automatic)').format(dhcpServer);
		if (status.dhcp_backend_problem)
			earlierWarning.push(E('div', { 'class': 'alert-message warning' }, [
				_('DHCP server of the cluster interfaces: %s').format(status.dhcp_backend_problem) ]));
		var keaImport = status.kea_import || {};
		if (keaImport.left > 0)
			earlierWarning.push(E('div', { 'class': 'alert-message warning' }, [
				E('p', {}, [ _('%d static leases of dnsmasq are not in Kea: open the import from dnsmasq in the Kea pages to take them over.').format(keaImport.left) ]),
				E('ul', {}, (keaImport.entries || []).map(function(entry) {
					return E('li', {}, [ entry.name || '-', ' ', entry.identifier || '', ' ', entry.address || '',
						' (', entry.status || '', ')' ]);
				}))
			]));

		// A maintenance of this node, or of the peer as its Kea tells
		var maintenance = status.maintenance || null;
		if (maintenance)
			earlierWarning.push(E('div', { 'class': 'alert-message notice' }, [
				E('p', {}, (maintenance.mode === 'persistent'
					? _('This node is in maintenance until you leave it (kept across reboots and upgrades), since %s: the peer holds the roles.')
					: _('This node is in maintenance until you leave it or it reboots, since %s: the peer holds the roles.'))
					.format(maintenance.since ? new Date(maintenance.since * 1000).toLocaleString() : '?'))
			]));
		if (status.peer_maintenance)
			earlierWarning.push(E('div', { 'class': 'alert-message notice' },
				_('The peer is in maintenance: this node holds the roles and serves every DHCP client.')));
		if (status.maintenance_result)
			earlierWarning.push(E('div', { 'class': 'alert-message' }, [
				E('strong', {}, _('Last maintenance command:')), ' ',
				E('span', { 'style': 'white-space: pre-line' }, [ status.maintenance_result ])
			]));

		return earlierWarning.concat([
			E('h3', {}, _('Cluster Status')),

			E('div', { 'class': 'cbi-section', 'style': 'display: flex; gap: 2em;' }, [
				E('div', { 'class': 'cbi-section-node', 'style': 'flex: 1;' }, [
					E('table', { 'class': 'table' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th', 'colspan': '2' }, _('Cluster Overview'))
						]),
						E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left' }, _('Cluster State')),
							E('td', { 'class': 'td left' }, [
								E('span', { 'class': stateClass }, [ clusterState ])
							])
						]),
						E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left' }, _('Node Role')),
							E('td', { 'class': 'td left' }, [
								E('span', { 'class': roleClass }, [ nodeRole ])
							])
						]),
						E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left' }, _('DHCP Server')),
							E('td', { 'class': 'td left' }, dhcpServer)
						])
					].concat(instanceNames.length > 1 ? instanceNames.map(function(name) {
						var instRole = instances[name];
						var instClass;
						switch (instRole) {
							case 'MASTER': instClass = 'label success'; break;
							case 'BACKUP': instClass = 'label notice'; break;
							case 'FAULT':  instClass = 'label important'; break;
							default:       instClass = 'label';
						}
						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left', 'style': 'padding-left: 2em;' },
								[ _('Instance: %s').format(name) ]),
							E('td', { 'class': 'td left' }, [
								E('span', { 'class': instClass }, [ instRole ])
							])
						]);
					}) : []))
				]),
				E('div', { 'class': 'cbi-section-node', 'style': 'flex: 1;' }, [
					E('table', { 'class': 'table' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th', 'colspan': '2' }, _('Last Synchronization'))
						]),
						E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left' }, _('Config Sync')),
							E('td', { 'class': 'td left' },
								this.formatLastSync(services.owsync, owsyncInstalled, syncStatus.config_last_sync))
						]),
						E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left' }, _('Lease Sync')),
							E('td', { 'class': 'td left' }, keaBackend
								? _('By Kea')
								: this.formatLastSync(services['lease-sync'], leaseSyncInstalled, syncStatus.lease_last_sync))
						])
					])
				])
			]),

			E('h3', {}, _('Service Status')),
			E('div', { 'class': 'cbi-section cbi-section-node' }, [
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Service')),
						E('th', { 'class': 'th' }, _('Status')),
						E('th', { 'class': 'th' }, _('PID')),
						E('th', { 'class': 'th' }, _('Uptime'))
					]),
					this.renderServiceRow('keepalived', services.keepalived, true),
					this.renderServiceRow('owsync', services.owsync, owsyncInstalled),
					this.renderServiceRow('lease-sync', services['lease-sync'], leaseSyncInstalled)
				].concat(keaBackend ? [
					this.renderKeaRow('kea-dhcp4', services['kea-dhcp4']),
					this.renderKeaRow('kea-dhcp6', services['kea-dhcp6'])
				] : []))
			]),

		].concat(this.renderUplinks(status.uplinks), this.renderMaintenance(maintenance, status.maintenance_running), [
			E('h3', {}, _('Peer Status')),
			E('div', { 'class': 'cbi-section cbi-section-node' }, [
				peers.length > 0 ?
					E('table', { 'class': 'table' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th' }, _('Peer Name')),
							E('th', { 'class': 'th' }, _('Address')),
							E('th', { 'class': 'th' }, _('State')),
							E('th', { 'class': 'th' }, _('Last Seen'))
						])
					].concat(peers.map(function(peer) {
						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left', 'data-title': _('Peer Name') }, peer.vrrp_only
								? [ peer.name || '-', ' ', E('span', { 'class': 'label' }, _('VRRP only')) ]
								: [ peer.name || '-' ]),
							E('td', { 'class': 'td left', 'data-title': _('Address') }, [ peer.address || '-' ]),
							E('td', { 'class': 'td left', 'data-title': _('State') },
								E('span', {
									'class': peer.online ? 'label success' : 'label important'
								}, peer.online ? _('Online') : _('Offline'))
							),
							E('td', { 'class': 'td left', 'data-title': _('Last Seen') }, [ peer.last_seen || '-' ])
						]);
					}))) :
					E('div', { 'class': 'alert-message warning' }, _('No peers configured'))
			])
		]));
	},

	// The interfaces that follow the role (Advanced Multi-WAN Management)
	renderUplinks: function(uplinks) {
		if (!Array.isArray(uplinks) || !uplinks.length)
			return [];

		var self = this;
		var stateLabels = {
			'up': [ 'label success', _('Up') ],
			'connecting': [ 'label notice', _('Connecting') ],
			'retrying': [ 'label warning', _('Retrying') ],
			'down': [ 'label', _('Down') ],
			'unknown': [ 'label important', _('Unknown interface') ]
		};

		return [
			E('h3', {}, _('Uplinks')),
			E('div', { 'class': 'cbi-section cbi-section-node' }, [
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Uplink')),
						E('th', { 'class': 'th' }, _('Mode')),
						E('th', { 'class': 'th' }, _('Role')),
						E('th', { 'class': 'th' }, _('Should be')),
						E('th', { 'class': 'th' }, _('State')),
						E('th', { 'class': 'th' }, _('Details'))
					])
				].concat(uplinks.map(function(u) {
					var label = stateLabels[u.state] || [ 'label', u.state || '?' ];
					var details = [];
					if (u.state === 'up' && u.uptime)
						details.push(_('up for %s').format(self.formatUptime(u.uptime)));
					if (u.error)
						details.push(u.error);
					if (u.retries)
						details.push(_('%d attempts by ha-cluster').format(u.retries));
					if (u.down_for)
						details.push(_('down for %s').format(self.formatUptime(u.down_for)));
					if (u.up_in)
						details.push(_('up in %d s').format(u.up_in));
					var stateCell = [ E('span', { 'class': label[0] }, [ label[1] ]) ];
					if (u.problem === 'down')
						stateCell.push(' ', E('span', { 'class': 'label important' }, _('MASTER without uplink')));
					else if (u.problem === 'down-on-backup')
						stateCell.push(' ', E('span', { 'class': 'label warning' }, _('Missing on this backup')));
					var desired = { 'up': _('up'), 'down': _('down'), 'wait': _('up after the delay') }[u.desired] || u.desired || '-';
					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left', 'data-title': _('Uplink') },
							[ u.name === u.interface ? u.name : u.name + ' (' + u.interface + ')' ]),
						E('td', { 'class': 'td left', 'data-title': _('Mode') },
							u.mode === 'always' ? _('Always') : _('Master only')),
						E('td', { 'class': 'td left', 'data-title': _('Role') },
							[ (u.role || '-') + (u.vrrp_instance ? ' (' + u.vrrp_instance + ')' : '') ]),
						E('td', { 'class': 'td left', 'data-title': _('Should be') }, [ desired ]),
						E('td', { 'class': 'td left', 'data-title': _('State') }, stateCell),
						E('td', { 'class': 'td left', 'data-title': _('Details') }, [ details.join(', ') || '-' ])
					]);
				})))
			])
		];
	},

	handleMaintenance: function(action, force) {
		return callMaintenance(action, force ? true : false).then(L.bind(function(res) {
			if (res && res.success) {
				ui.addNotification(null, E('p', _('Maintenance command started: the status shows when the hand-over is done.')), 'info');
				return;
			}
			var error = (res && res.error) || _('No answer');
			var body = [ E('p', {}, [ error ]) ];
			if (action !== 'off' && /^Refused/.test(error))
				body.push(E('div', { 'class': 'right' }, E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(this, 'handleMaintenance', action, true)
				}, _('Enter anyway (force)'))));
			ui.addNotification(_('Maintenance'), body, 'warning');
		}, this)).catch(function(err) {
			ui.addNotification(null, E('p', {}, [ _('Maintenance command failed: %s').format(err.message || err) ]), 'danger');
		});
	},

	// Maintenance of this node, as pfSense has it: until reboot, or kept
	renderMaintenance: function(maintenance, running) {
		var mode = (maintenance && maintenance.mode) || 'none';
		var button = L.bind(function(action, title, description, disabled, style) {
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, title),
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button ' + (style || 'cbi-button-action'),
						'disabled': (disabled || running) ? '' : null,
						'click': ui.createHandlerFn(this, 'handleMaintenance', action, false)
					}, title),
					E('div', { 'class': 'cbi-value-description' }, description)
				])
			]);
		}, this);

		return [
			E('h3', {}, _('Maintenance')),
			running ? E('div', { 'class': 'alert-message notice' },
				_('A maintenance command is running: the hand-over takes a few seconds.')) : '',
			E('div', { 'class': 'cbi-section cbi-section-node' }, [
				button('temp', _('Enter maintenance until reboot'),
					_('This node hands its VRRP roles, DHCP (Kea) and Master only uplinks to the peer and stays out until you leave maintenance or the node reboots. Also entered automatically before a sysupgrade. The peer must be healthy.'),
					mode === 'temp'),
				button('on', _('Enter persistent maintenance'),
					_('Like maintenance until reboot, but kept across reboots and upgrades: the node stays a low-priority backup and does not take the role back until you leave maintenance. Use it for work after which the node must be checked first. The peer must be healthy.'),
					mode === 'persistent'),
				button('off', _('Leave maintenance'),
					_('The node rejoins: VRRP priorities, Kea and uplinks return to normal. Whether it takes the role back depends on preemption.'),
					mode === 'none', 'cbi-button-positive')
			])
		];
	},

	render: function(data) {
		var statusData = data[0];
		var owsyncInstalled = data[1] != null;
		var leaseSyncInstalled = data[2] != null;

		var view = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('High Availability Status')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Real-time status of the HA cluster. Updates every 5 seconds.'))
		]);

		var content = E('div', { 'id': 'ha_status_content' });
		view.appendChild(content);
		dom.content(content, this.renderStatus(statusData, owsyncInstalled, leaseSyncInstalled));

		poll.add(L.bind(function() {
			return this.loadData().then(L.bind(function(data) {
				var statusContent = document.getElementById('ha_status_content');
				if (statusContent) {
					dom.content(statusContent, this.renderStatus(data, owsyncInstalled, leaseSyncInstalled));
				}
			}, this));
		}, this), 5);

		return view;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
