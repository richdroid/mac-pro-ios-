// The bridge's power feeds (/api/mac/links, fans, temps, updates, storage, startup), as a stand-in Mac for the build's
// shots. Made-up names and addresses only (the repository is public). Returns true when it answered.
const now = () => Date.now();
const link = (id, name, state, detail, extra = {}) => ({ id, name, state, detail, checkedAt: now(), can: [], ...extra });
let restartAt = 0;
const feeds = {
  '/api/mac/links': () => ({ t: now(), healthAt: now(), links: [
    link('tailscale', 'Tailscale', 'up', 'Running · 4 of 6 devices online', { endpoint: '100.64.0.10 · mac-pro.example.ts.net', note: 'Never stopped from here: the phone reaches the Mac through it.' }),
    link('serve', 'Tailscale Serve', 'up', 'https → the bridge, tailnet only', { endpoint: 'https://mac-pro.example.ts.net', note: 'The bridge points it again every minute by itself.' }),
    link('funnel', 'Tailscale Funnel', 'off', 'Off, as it should be'),
    link('bridge', 'Bridge', 'up', 'Answering', { endpoint: '127.0.0.1:8787', pid: 4012, uptime: 51840, can: ['restart'], note: 'Back in a few seconds; the app reconnects by itself.' }),
    (now() - restartAt < 6000 ? link('public', 'Public link', 'starting', 'Tunnel running, no address yet', { endpoint: '', pid: 51234, uptime: Math.round((now() - restartAt) / 1000), can: ['restart'], note: 'A restart gives the public link a new address.' })
      : link('public', 'Public link', 'up', 'Cloudflare tunnel up', { endpoint: restartAt ? 'https://other-words.trycloudflare.com' : 'https://example-words.trycloudflare.com', pid: restartAt ? 51234 : 841, uptime: restartAt ? Math.round((now() - restartAt) / 1000) : 188400, can: ['restart'], note: 'A restart gives the public link a new address.' })),
    link('novnc', 'Screen link (noVNC)', 'up', 'Screen Sharing answers; Screen relays through the bridge', { endpoint: '/novnc', note: 'Status only. Screen Sharing is a macOS setting.' }),
    link('letterboxd', 'Letterboxd sign-in relay', 'up', 'Running, listening on 8767', { endpoint: '100.64.0.10:8767', pid: 8486, uptime: 187900, can: ['restart'] }),
    link('tv', 'TV link (adb)', 'up', 'Connected'),
    link('chumby-remote', 'Chumby proxy', 'up', 'Running', { endpoint: 'local.chumby-remote', pid: 40432, uptime: 75500, can: ['restart'] }),
    link('chumby', 'Chumby', 'up', 'Answering'),
    link('sessions', 'Claude sessions', 'up', '6 of 6 kept running · 2 others'),
  ] }),
  '/api/mac/fans': () => ({ t: now(), stale: false, fans: [{ index: 0, name: 'Main fan', rpm: 1184, min: 790, max: 1900, target: 1180, mode: 'auto' }], control: { state: 'needs-setup', installed: false, setup: 'sudo ~/code/Tools/macpro-console/helper/install-fan-helper.sh', title: 'Fan floor helper not installed', note: 'Speeds are read only and the Mac sets them.' } }),
  '/api/mac/temps': () => {
    const named = [['CPU', 'TCXc', 54, 88, 95], ['GPU A', 'TG0D', 44, 90, 100], ['GPU B', 'TG1D', 46, 90, 100], ['Memory', 'TM0P', 49, 85, 95], ['Chipset', 'TPCD', 52, 85, 95], ['Drive', 'TH0A', 41, 65, 75], ['Power supply', 'Tp0F', 38, 80, 90], ['Intake air', 'TA0P', 24, 40, 45]].map(([name, key, c, warn, hot]) => ({ name, key, c, warn, hot }));
    const all = [['TA0P', 'Air', 'Intake air', 24], ['TA0V', 'Air', 'Ambient', 21], ['TC0P', 'CPU', 'CPU proximity', 47], ['TC0c', 'CPU', 'CPU core 1', 53], ['TC1c', 'CPU', 'CPU core 2', 51], ['TC2c', 'CPU', 'CPU core 3', 52], ['TC3c', 'CPU', 'CPU core 4', 54], ['TCXc', 'CPU', 'CPU (hottest core)', 54], ['TG0D', 'GPU A', 'GPU A die', 44], ['TG0P', 'GPU A', 'GPU A proximity', 40], ['TG1D', 'GPU B', 'GPU B die', 46], ['TG1P', 'GPU B', 'GPU B proximity', 41], ['TH0A', 'Drive', 'Drive', 41], ['TM0P', 'Memory', 'Memory proximity', 49], ['TPCD', 'Chipset', 'Chipset die', 52], ['Tp0F', 'Power supply', 'Power supply', 38], ['TI0P', 'Other', 'Other · TI0P', 33]].map(([key, group, label, c]) => ({ key, group, label, c }));
    return { t: now(), stale: false, named, all, hottest: { name: 'CPU', c: 54 }, verdict: 'Normal' };
  },
  '/api/mac/updates': () => ({ t: now(), macos: { current: '26.7.2 (25G332)', checkedAt: now() - 7200e3, checking: false, pending: [], error: null, autoInstall: false, admin: true, command: 'softwareupdate --install --all --restart', risk: 'A macOS update removes the OpenCore root patches. Updates go through the macOS tab, which patches again after.' },
    oclp: { installed: '3.0.0', latest: '3.0.0-rc.5', latestPre: true, newer: false, patchedFor: '26.7.2', patches: 'HEALTHY: macOS 26.7.2 (25G332), OCLP 3.0.0', healthy: true, admin: true, command: 'open -a OpenCore-Patcher' }, brew: null,
    apps: [{ name: 'Tailscale', installed: '1.104.4', latest: null, how: 'Updates itself' }] }),
  '/api/mac/storage': () => ({ t: now(), volumes: [{ name: 'Macintosh HD', mount: '/System/Volumes/Data', total: 250790436864, free: 37826465792, kind: 'APFS', internal: true }],
    home: [['Library', 91e9], ['code', 48e9], ['.cache', 12e9], ['Applications', 9.8e9], ['.local', 6.1e9]].map(([name, bytes]) => ({ path: '/Users/you/' + name, name, bytes })), homeAt: now() - 300e3, cleanup: [] }),
  // The macOS upgrade as steps (/api/mac/upgrade): an update waiting, short of room (the same disk as
  // /api/mac/storage's, so the tiles agree), the nightly install failed twice.
  '/api/mac/upgrade': () => ({ t: now(), current: '26.7.2 (25G332)', target: { label: 'macOS Tahoe 26.7.3', version: '26.7.3', size: null }, free: 37826465792, total: 250790436864, required: 34.53e9, want: 41e9,
    cleanups: [{ id: 'trash', name: 'Trash', why: 'Things you already threw away', bytes: 1.1e9 }, { id: 'caches', name: 'App caches', why: 'Apps rebuild these when they next run', bytes: 3.8e9 }, { id: 'old-logs', name: 'Old logs', why: 'Rotated logs and crash reports over two weeks old', bytes: 7e6 }],
    folders: [['Virtual Machines', 69e9], ['Library', 22e9], ['code', 21.5e9], ['Applications', 4.2e9], ['Downloads', 1.6e9]].map(([n, bytes]) => ({ path: '/Users/you/' + n, name: '~/' + n, bytes })),
    patcher: { installed: '3.0.0', latest: '3.0.0', newer: false, ready: true }, agent: { installed: true, status: 'Update failed: not enough disk space', attempts: 2, max: 4, blocked: false, shortRoom: true, lastTry: '2026-11-20 03:30:04' },
    download: null, patches: { forBuild: '25G332', thisBuild: '25G332', ok: true }, phase: 'room' }),
  // The TV as the bridge says it (tv.js /api/tv/status): on, an episode playing in Stremio.
  '/api/tv/status': () => ({ online: true, at: now(), screen: 'on', app: 'com.stremio.one', session: { playing: true, description: ['Severance', 'Season 2 · Episode 4'] }, music: null }),
  '/api/mac/startup': () => ({ t: now(), items: [
    ['local.mac-dash', '/usr/local/bin/node ~/code/Tools/mac-dash/server.js', 4012, 'bridge'], ['local.mac-dash-tunnel', '/bin/bash ~/code/Tools/mac-dash/keep-tunnel.sh', 841, null],
    ['local.chumby-remote', '/usr/bin/python3 -I ~/code/chumby-remote/chumby_remote.py', 40432, null], ['local.keep-awake', '/usr/bin/caffeinate -ims', 702, null], ['local.claude-sessions', '/bin/bash ~/code/Tools/keep-sessions.sh', null, 'claude'],
  ].map(([label, program, pid, prot]) => ({ label, kind: 'agent', domain: 'user', path: '~/Library/LaunchAgents/' + label + '.plist', program, loaded: true, pid, lastExit: 0, runAtLoad: true, keepAlive: pid !== null, interval: pid === null ? 120 : null, disabled: false, protected: prot, editable: true }))
    .concat([{ label: 'local.oclp-tahoe.agent', kind: 'daemon', domain: 'system', path: '/Library/LaunchDaemons/local.oclp-tahoe.agent.plist', program: '/bin/bash /Library/Application Support/oclp-tahoe/agent.sh', loaded: true, pid: null, lastExit: 0, runAtLoad: true, keepAlive: false, interval: 300, disabled: false, protected: null, editable: false, command: 'sudo launchctl bootout system/local.oclp-tahoe.agent' }]) }),
};
// The Console on the Mac as the bridge relays it (API.md "Console remote"): a command is acked after 0.7 s, and changes
// the state that GET /api/mac/console reports.
const consoleState = { running: true, frontmost: true, fullscreen: true, page: 'temps', board: null, rotate: false, rotateSecs: 45, mode: 'desk', rotating: ['machine', 'media', 'home', 'work', 'tonight'], animations: 'full', display: 'awake', glance: false, at: Date.now() };
module.exports = (q, s) => {
  const u = new URL(q.url, 'http://x');
  // Music on the Mac (the Dashboard's Music section): port 9061 is a Mac whose lyrics session is on (the Console sent aside), any other has it off.
  const lyricsOn = q.socket.localPort === 9061;
  if (u.pathname === '/api/mac/music/now') { s.end(JSON.stringify(lyricsOn ? { state: 'playing', title: 'Sample Song', artist: 'Sample Artist', session: { on: true, speaker: 'HK Invoke_C20142', speakerConnected: true } } : { state: 'stopped', session: { on: false } })); return true; }
  if (u.pathname === '/api/mac/audio') { s.end(JSON.stringify({ outputs: [{ id: 'hk', name: 'HK Invoke_C20142', connected: lyricsOn }, { id: 'mbp', name: 'Mac Pro Speakers', connected: false }], preferred: 'hk' })); return true; }
  if (u.pathname === '/api/mac/console' && q.method === 'GET') { s.end(JSON.stringify(lyricsOn ? { ...consoleState, frontmost: false } : consoleState)); return true; }
  if (u.pathname === '/api/mac/console' && q.method === 'GET') { s.end(JSON.stringify(consoleState)); return true; }
  // The actions mirror and shared dismissals (2026-11-13): nothing under way; a dismissal is taken.
  if (u.pathname === '/api/mac/actions/current') { s.end(JSON.stringify({ action: null })); return true; }
  if (u.pathname === '/api/mac/alerts/dismiss' && q.method === 'POST') { s.end(JSON.stringify({ ok: true })); return true; }
  if (u.pathname === '/api/mac/console/command' && q.method === 'POST') {
    let body = ''; q.on('data', c => { body += c; }); q.on('end', () => {
      let b = {}; try { b = JSON.parse(body); } catch {}
      const cmd = b.cmd, arg = b.arg || '';
      if (cmd === 'page') { consoleState.page = arg; consoleState.board = null; }
      if (cmd === 'board' && (arg === 'next' || arg === 'previous')) {
        const r = consoleState.rotating, i = r.indexOf(consoleState.board);
        consoleState.board = r[i < 0 ? 0 : (i + (arg === 'next' ? 1 : -1) + r.length) % r.length]; consoleState.page = 'boards';
      } else if (cmd === 'board') { consoleState.board = arg === 'off' ? null : arg; if (arg !== 'off') consoleState.page = 'boards'; }
      if (cmd === 'rotate') consoleState.rotate = arg === 'on';
      if (cmd === 'glance') consoleState.glance = arg === 'on';
      if (cmd === 'animations') consoleState.animations = arg;
      if (cmd === 'display') consoleState.display = arg === 'wake' ? 'awake' : 'asleep';
      if (cmd === 'show') { consoleState.running = true; consoleState.frontmost = true; consoleState.fullscreen = true; }
      if (cmd === 'hide') consoleState.frontmost = false;
      setTimeout(() => s.end(JSON.stringify({ ok: true, acked: true, console: consoleState })), 700);
    });
    return true;
  }
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
      if (b.dryRun) { s.setHeader('X-MP-Nonce', 'c0ffee00c0ffee00c0ffee00c0ffee00'); return s.end(JSON.stringify({ ok: true, command: b.action, dryRun: true, say: 'Dry run: would remove 3.5 GB. Nothing was removed.' })); }
      s.end(JSON.stringify({ ok: true, command: b.action, say: b.action === 'fix' ? 'All running; nothing needed fixing.' : 'Done.', rows: [{ part: 'tv', label: 'TV link', state: 'ok', say: 'Connected' }] }));
    });
    return true;
  }
  // A restart of the public link: starting for 6 s with a new process, then up again (the restart film).
  if (q.method === 'POST' && u.pathname === '/api/mac/links/action') { restartAt = now(); setTimeout(() => s.end(JSON.stringify({ ok: true, say: 'Public link restarted (now process 51234)' })), 1500); return true; }
  if (q.method === 'POST' && u.pathname.startsWith('/api/mac/') && u.pathname.endsWith('/action')) { s.end(JSON.stringify({ ok: true, say: 'Restarted (now process 51234)' })); return true; }
  const f = feeds[u.pathname];
  if (!f) return false;
  s.end(JSON.stringify(f()));
  return true;
};
