// The bridge's power feeds (/api/mac/links, fans, temps, updates, storage, startup), as a stand-in Mac for the build's
// shots. Made-up names and addresses only (the repository is public). Returns true when it answered.
const now = () => Date.now();
const link = (id, name, state, detail, extra = {}) => ({ id, name, state, detail, checkedAt: now(), can: [], ...extra });
const feeds = {
  '/api/mac/links': () => ({ t: now(), healthAt: now(), links: [
    link('tailscale', 'Tailscale', 'up', 'Running · 4 of 6 devices online', { endpoint: '100.64.0.10 · mac-pro.example.ts.net', note: 'Never stopped from here: the phone reaches the Mac through it.' }),
    link('serve', 'Tailscale Serve', 'up', 'https → the bridge, tailnet only', { endpoint: 'https://mac-pro.example.ts.net', note: 'The bridge points it again every minute by itself.' }),
    link('funnel', 'Tailscale Funnel', 'off', 'Off, as it should be'),
    link('bridge', 'Bridge', 'up', 'Answering', { endpoint: '127.0.0.1:8787', pid: 4012, uptime: 51840, can: ['restart'], note: 'Back in a few seconds; the app reconnects by itself.' }),
    link('public', 'Public link', 'up', 'Cloudflare tunnel up', { endpoint: 'https://example-words.trycloudflare.com', pid: 841, uptime: 188400, can: ['restart'], note: 'A restart gives the public link a new address.' }),
    link('novnc', 'Screen link (noVNC)', 'up', 'Screen Sharing answers; Screen relays through the bridge', { endpoint: '/novnc', note: 'Status only. Screen Sharing is a macOS setting.' }),
    link('letterboxd', 'Letterboxd sign-in relay', 'up', 'Running, listening on 8767', { endpoint: '100.64.0.10:8767', pid: 8486, uptime: 187900, can: ['restart'] }),
    link('tv', 'TV link (adb)', 'up', 'Connected'),
    link('chumby-remote', 'Chumby proxy', 'up', 'Running', { endpoint: 'local.chumby-remote', pid: 40432, uptime: 75500, can: ['restart'] }),
    link('chumby', 'Chumby', 'up', 'Answering'),
    link('sessions', 'Claude sessions', 'up', '6 of 6 running'),
  ] }),
  '/api/mac/fans': () => ({ t: now(), stale: false, fans: [{ index: 0, name: 'Main fan', rpm: 1184, min: 790, max: 1900, target: 1180, mode: 'auto' }], control: { state: 'needs-setup', setup: null, note: 'Fan control needs a small helper Richard installs once himself; until then speeds are read only and the Mac sets them.' } }),
  '/api/mac/temps': () => {
    const named = [['CPU', 'TCXc', 54, 88, 95], ['GPU A', 'TG0D', 44, 90, 100], ['GPU B', 'TG1D', 46, 90, 100], ['Memory', 'TM0P', 49, 85, 95], ['Chipset', 'TPCD', 52, 85, 95], ['Drive', 'TH0A', 41, 65, 75], ['Power supply', 'Tp0F', 38, 80, 90], ['Intake air', 'TA0P', 24, 40, 45]].map(([name, key, c, warn, hot]) => ({ name, key, c, warn, hot }));
    const all = [['TA0P', 'Air', 'Intake air', 24], ['TA0V', 'Air', 'Ambient', 21], ['TC0P', 'CPU', 'CPU proximity', 47], ['TC0c', 'CPU', 'CPU core 1', 53], ['TC1c', 'CPU', 'CPU core 2', 51], ['TC2c', 'CPU', 'CPU core 3', 52], ['TC3c', 'CPU', 'CPU core 4', 54], ['TCXc', 'CPU', 'CPU (hottest core)', 54], ['TG0D', 'GPU A', 'GPU A die', 44], ['TG0P', 'GPU A', 'GPU A proximity', 40], ['TG1D', 'GPU B', 'GPU B die', 46], ['TG1P', 'GPU B', 'GPU B proximity', 41], ['TH0A', 'Drive', 'Drive', 41], ['TM0P', 'Memory', 'Memory proximity', 49], ['TPCD', 'Chipset', 'Chipset die', 52], ['Tp0F', 'Power supply', 'Power supply', 38], ['TI0P', 'Other', 'Other · TI0P', 33]].map(([key, group, label, c]) => ({ key, group, label, c }));
    return { t: now(), stale: false, named, all, hottest: { name: 'CPU', c: 54 }, verdict: 'Normal' };
  },
  '/api/mac/updates': () => ({ t: now(), macos: { current: '26.7.2 (25G332)', checkedAt: now() - 7200e3, checking: false, pending: [], error: null, autoInstall: false, admin: true, command: 'softwareupdate --install --all --restart', risk: 'A macOS update removes the OpenCore root patches. Updates go through the macOS tab, which patches again after.' },
    oclp: { installed: '3.0.0', latest: '3.0.0-rc.5', latestPre: true, newer: false, patchedFor: '26.7.2', patches: 'HEALTHY: macOS 26.7.2 (25G332), OCLP 3.0.0-rc.5', healthy: true, admin: true, command: 'open -a OpenCore-Patcher' }, brew: null,
    apps: [{ name: 'Tailscale', installed: '1.104.4', latest: null, how: 'Updates itself' }] }),
  '/api/mac/storage': () => ({ t: now(), volumes: [{ name: 'Macintosh HD', mount: '/System/Volumes/Data', total: 250790436864, free: 37826465792, kind: 'APFS', internal: true }],
    home: [['Library', 91e9], ['code', 48e9], ['.cache', 12e9], ['Applications', 9.8e9], ['.local', 6.1e9]].map(([name, bytes]) => ({ path: '/Users/you/' + name, name, bytes })), homeAt: now() - 300e3, cleanup: [] }),
  '/api/mac/startup': () => ({ t: now(), items: [
    ['local.mac-dash', '/usr/local/bin/node ~/code/Tools/mac-dash/server.js', 4012, 'bridge'], ['local.mac-dash-tunnel', '/bin/bash ~/code/Tools/mac-dash/keep-tunnel.sh', 841, null],
    ['local.chumby-remote', '/usr/bin/python3 -I ~/code/chumby-remote/chumby_remote.py', 40432, null], ['local.keep-awake', '/usr/bin/caffeinate -ims', 702, null], ['local.claude-sessions', '/bin/bash ~/code/Tools/keep-sessions.sh', null, 'claude'],
  ].map(([label, program, pid, prot]) => ({ label, kind: 'agent', domain: 'user', path: '~/Library/LaunchAgents/' + label + '.plist', program, loaded: true, pid, lastExit: 0, runAtLoad: true, keepAlive: pid !== null, interval: pid === null ? 120 : null, disabled: false, protected: prot, editable: true }))
    .concat([{ label: 'local.oclp-tahoe.agent', kind: 'daemon', domain: 'system', path: '/Library/LaunchDaemons/local.oclp-tahoe.agent.plist', program: '/bin/bash /Library/Application Support/oclp-tahoe/agent.sh', loaded: true, pid: null, lastExit: 0, runAtLoad: true, keepAlive: false, interval: 300, disabled: false, protected: null, editable: false, command: 'sudo launchctl bootout system/local.oclp-tahoe.agent' }]) }),
};
module.exports = (q, s) => {
  const u = new URL(q.url, 'http://x');
  if (u.pathname === '/api/trend' && /^fan:\d$/.test(u.searchParams.get('m') || '')) {
    const t = now();
    s.end(JSON.stringify({ points: Array.from({ length: 1440 }, (_, i) => ({ t: t - (1440 - i) * 60000, v: Math.round(1000 + 120 * Math.sin(i / 120) + (i % 300 < 20 ? 300 : 0)) })) }));
    return true;
  }
  if (u.pathname === '/api/mac/storage/folder') {
    s.end(JSON.stringify({ path: u.searchParams.get('path'), measuring: false, at: now(), children: [['Caches', 21e9], ['Developer', 18e9], ['Application Support', 14e9], ['Containers', null, true], ['Logs', 2.2e9]].map(([name, bytes, priv]) => ({ name, bytes, dir: true, private: !!priv })) }));
    return true;
  }
  // mp's actions: a made-up action is refused (the app's probe), a dry run hands out a nonce, a run answers its line.
  if (u.pathname === '/api/mp') {
    if (q.method === 'GET') { s.statusCode = 404; s.end(JSON.stringify({ ok: false, command: u.searchParams.get('action') || '', say: 'Not an action the Mac takes from here.' })); return true; }
    let body = ''; q.on('data', c => { body += c; }); q.on('end', () => {
      let b = {}; try { b = JSON.parse(body); } catch {}
      if (b.dryRun) { s.setHeader('X-MP-Nonce', 'c0ffee00c0ffee00c0ffee00c0ffee00'); return s.end(JSON.stringify({ ok: true, command: b.action, dryRun: true, say: 'Dry run: would remove 3.4 GB. Nothing was removed.' })); }
      s.end(JSON.stringify({ ok: true, command: b.action, say: b.action === 'fix' ? 'All running; nothing needed fixing.' : 'Done.', rows: [{ part: 'tv', label: 'TV link', state: 'ok', say: 'Connected' }] }));
    });
    return true;
  }
  if (q.method === 'POST' && u.pathname.startsWith('/api/mac/') && u.pathname.endsWith('/action')) { s.end(JSON.stringify({ ok: true, say: 'Restarted (now process 51234)' })); return true; }
  const f = feeds[u.pathname];
  if (!f) return false;
  s.end(JSON.stringify(f()));
  return true;
};
