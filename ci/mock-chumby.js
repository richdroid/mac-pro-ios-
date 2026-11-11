// Sample Chumby answers so the cloud build can screenshot every tab without a real device.
const http = require('http');
const alarm = (o) => ({ name: '', enabled: '1', time: '420', when: 'weekday', type: 'beep', arg: 'Beep', param: '', param_description: 'Beep', duration: '30', snooze: '9', auto_dismiss: '0', action: '', action_param: '', backup: '0', backupDelay: '5', own: '', ...o });
const data = {
  tok: { t: 'test' },
  // Every key the real a=sys and a=state carry (chalarm.c do_sys, do_state), so the build reads what the phone reads.
  sys: { ok: true, up: 291000, memFree: 22000, memTotal: 62000, night: 0, cached: 18000, buffers: 3600, tmpUsed: 4000, playerRss: 12000, procs: 44, pspFree: 3100, load: 0.42, wifi: 71, vol: 40, shuffle: 0, airplayOn: true, chan: 'Default', cp: '2.8.87b3', lock: '', wall: 1, ring: '', nap: 0, resets: 0, resetAt: 0, tw: ['NASA', 'BBCBreaking'], twopts: 'new 0 0 0', roms: [] },
  state: {
    ok: true, local: '', volume: 80, fade: 30, next: 0, pending: false, shuffle: 0, channel: 'Default', skipped: null,
    ringing: null, music: null, song: null, rang: null, missed: [], calOverride: 1, calTpl: null, pandoraLast: '',
    alarms: [alarm({ name: 'Work', time: '405' }), alarm({ name: 'Weekend', time: '570', when: 'weekend', enabled: '0', type: 'audio', arg: 'directurl', param_description: 'Jazz Radio' })],
    streams: [{ id: 's1', name: 'Jazz Radio', url: 'http://example.com/jazz.mp3', mimetype: 'audio/mpeg' }],
    tones: ['Beep', 'Bells', 'Chime'], channels: [{ id: 'A', name: 'Default' }, { id: 'B', name: 'News' }],
    pandora: [{ id: '1', name: 'Morning Mix' }], pandoraScan: '',
    schedule: [{ time: '22:30', cmd: 'night', val: 'on' }, { time: '07:00', cmd: 'night', val: 'off' }],
    channelNames: ['Default', 'News'], widgetNames: ['Clock', 'Weather', 'X'], mine: [{ name: 'X', secs: 60 }, { name: 'NYT', secs: 45 }],
  },
  chlist: { cur: 'A', names: [['W3', 'Moon Phase']], channels: [{ id: 'A', conf: [['W1', '1', '30'], ['W2', '0', '0'], ['W5', '1', '45']], list: [['#', 'Default'], ['W1', 'Clock', '30'], ['W2', 'Weather', '15'], ['W5', 'NYT Top Headlines', '45']] }, { id: 'B', conf: [], list: [['#', 'News'], ['W4', 'NYT', '45']] }] },
};
// The Chumby's clock, as a=state gives it: "now" in seconds and "local" as its wall time.
const clockNow = () => { const d = new Date(), p = n => String(n).padStart(2, '0'); return { now: Math.floor(d / 1000), local: `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}` }; };
const stateNow = v => ({ ...v, ...clockNow() });
// What the real do_save turns down, so a save the Chumby would refuse fails here too (a backupDelay of 0 cost every nap
// from 11-05 while the build saw nothing). Returns the Chumby's own error, or null.
const ALARM_KEYS = ['name', 'enabled', 'time', 'when', 'type', 'arg', 'param', 'param_description', 'duration', 'snooze', 'auto_dismiss', 'action', 'action_param', 'backup', 'backupDelay', 'own'];
// As of 510ac74 a missing or odd backupDelay is written as the stock 5, never refused; text over its length or with a
// control character is "bad text"; tpl must name an alarm in the list.
const TEXT_MAX = { name: 64, arg: 64, param: 1024, param_description: 128, action_param: 64 };
function saveProblem(f) {
  const n = +f.get('n');
  if (!/^\d+$/.test(f.get('n') || '') || n > 16) return 'bad count';
  if (f.has('tpl') && !(/^\d+$/.test(f.get('tpl')) && +f.get('tpl') < n)) return 'bad tpl';
  const range = { enabled: [0, 1], duration: [-1, 1440], snooze: [1, 120], auto_dismiss: [0, 1], backup: [0, 1], time: [0, 2e9] };
  for (let i = 0; i < n; i++) {
    for (const [k, max] of Object.entries(TEXT_MAX)) {
      const v = f.get(i + '_' + k) || '';
      if (v.length > max || /[\x00-\x1f]/.test(v)) return 'bad text';
    }
    if (!['once', 'daily', 'weekday', 'weekend', 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'].includes(f.get(i + '_when'))) return 'bad choice';
    if (!['none', 'beep', 'audio', 'widget'].includes(f.get(i + '_type')) || !['', 'profile', 'nightmode', 'power', 'bright'].includes(f.get(i + '_action') || '')) return 'bad choice';
    for (const [k, [lo, hi]] of Object.entries(range)) {
      const v = f.get(i + '_' + k) || '';
      if (!/^-?\d+$/.test(v) || +v < lo || +v > hi) return 'bad number';
    }
    if (f.get(i + '_when') !== 'once' && +f.get(i + '_time') > 1439) return 'bad time';
  }
  return null;
}
http.createServer((q, s) => {
  if (chumbyScene(q, s)) return;   // the Chumby app's poses; see the block at the end
  const a = new URL(q.url, 'http://x').searchParams.get('a');
  if (a === 'save' && q.method === 'POST') {
    let body = ''; q.on('data', c => body += c);
    q.on('end', () => { const why = saveProblem(new URLSearchParams(body)); s.setHeader('content-type', 'application/json'); s.end(JSON.stringify(why ? { ok: false, error: why } : { ok: true })); });
    return;
  }
  if (a === 'state') { s.setHeader('content-type', 'application/json'); s.end(JSON.stringify(stateNow(data.state))); return; }
  if (a === 'shot') { s.setHeader('content-type', 'image/jpeg'); s.end(require('fs').readFileSync(__dirname + '/shot.jpg')); return; }
  if (a === 'cat') { s.end('<a href="/guide/AB-1/category"><img alt="Clocks"></a>'); return; }
  // Outside the live scenes nothing changes, so the two actions that are confirmed by reading the state back answer as an
  // older Chumby does, and the app goes its older way.
  if (q.method === 'POST') { s.end(a === 'once' || a === 'pstation' ? '{"ok":false,"error":"unknown action"}' : '{"ok":true}'); return; }
  if (data[a]) { s.setHeader('content-type', 'application/json'); s.end(JSON.stringify(data[a])); return; }
  s.statusCode = 404; s.end();
}).listen(9000, '127.0.0.1');
// And a sample Mac for the Mac Pro app.
const macMock = JSON.parse(require('fs').readFileSync(__dirname + '/mock-status.json'));
{ // Times relative to now, so the screenshots show what a real day looks like.
  const now = Date.now(), plan = macMock.usage.plan;
  plan.at = now - 120000; plan.fiveHourResets = now + 3 * 3600e3; plan.sevenDayResets = now + 4 * 86400e3;
  // As the real Mac reports it since November: Claude no longer sends a 5-hour limit for this plan.
  plan.fiveHour = null; plan.fiveHourResets = null;
  macMock.iosApps.apps.forEach(a => { if (a.expires) { a.expires = now + 6 * 86400e3; a.installedAt = now - 86400e3; } });
  macMock.usage.hours.forEach((h, i, all) => { h.t = now - (all.length - 1 - i) * 3600e3; });
  macMock.claude.sessions = [
    { name: 'Tahoe upgrade', status: 'busy', cwd: '~/code', remote: true, updated: now - 240000, key: null, restartable: false, stuck: false },
    { name: 'TV plugin', status: 'busy', cwd: '~/code', remote: true, updated: now - 7200000, key: 'tv', restartable: true, stuck: true },
    { name: 'Chumby widget', status: 'idle', cwd: '~/code', remote: true, updated: now - 3600000, key: 'chumby', restartable: true, stuck: false },
    { name: 'build', status: 'stopped', cwd: '~/code', remote: false, updated: null, key: 'build', restartable: true, stuck: false },
  ];
}
// The apps as the real Mac reports them (2026-11-07): most idle at 0 % CPU, each app's memory with its helpers', one busy,
// and one that has quit with no figures (an older Mac still listed those), which the phone must leave out.
macMock.apps = [
  { name: 'Calendar', pid: 9, front: false },
  { name: 'Claude', pid: 10, cpu: 0.7, mem: 1790000000 }, { name: 'Code', pid: 11, cpu: 0, mem: 1450000000 },
  { name: 'Finder', pid: 13, cpu: 0, mem: 132000000 }, { name: 'Google Chrome', pid: 12, cpu: 14.2, mem: 2160000000 },
  { name: 'Music', pid: 14, cpu: 0, mem: 399000000 }, { name: 'System Settings', pid: 15, cpu: 0, mem: 137000000 },
  { name: 'Tailscale', pid: 16, cpu: 0, mem: 105000000 }, { name: 'Terminal', pid: 17, cpu: 2.4, mem: 363000000 },
];
macMock.installed = ['Calendar', 'Claude', 'Code', 'Finder', 'Google Chrome', 'Music', 'Safari', 'System Settings', 'Tailscale', 'Terminal', 'TextEdit', 'VLC'];
macMock.displayOn = false;
const macStatus = JSON.stringify(macMock);
const macProc = (pid, name, cpu, mem, locked) => ({ pid, start: 'Fri Oct 30 23:11:35 2026', name, cpu, mem: mem * 1048576, locked });
const macProcs = JSON.stringify({
  cpu: [macProc(40, 'Google Chrome Helper', 84, 610, null), macProc(41, 'WindowServer', 22, 240, 'System process'), macProc(42, 'Claude Code', 12, 690, 'Claude session'), macProc(43, 'Music', 6, 380, null), macProc(44, 'node', 3, 310, 'The dashboard'), macProc(45, 'Tailscale', 2, 118, 'Keeps remote access')],
  mem: [macProc(42, 'Claude Code', 12, 690, 'Claude session'), macProc(40, 'Google Chrome Helper', 84, 610, null), macProc(46, 'mediaanalysisd', 0, 490, 'System process'), macProc(43, 'Music', 6, 380, null), macProc(44, 'node', 3, 310, 'The dashboard'), macProc(47, 'Code Helper', 1, 290, null)],
});
// His apps' own icons for the Apps tab, from the repo's icon sets.
const appIcon = (q, s) => { const f = { 'MacPro.ipa': 'Assets.xcassets', 'Chumby.ipa': 'ChumbyApp/Assets.xcassets', 'TV.ipa': 'TVApp/Assets.xcassets' }[decodeURIComponent(q.url.slice('/ios/icon/'.length))]; try { const png = require('fs').readFileSync(require('path').join(__dirname, '..', f, 'AppIcon.appiconset/icon.png')); s.setHeader('content-type', 'image/png'); s.end(png); } catch { s.statusCode = 404; s.end(); } };
// The Mac's routes, for the still Mac (9001) and the one whose figures move (9021).
const macRoutes = (q, s, status, live) => { if (q.url.startsWith('/ios/icon/')) return appIcon(q, s); s.setHeader('content-type', 'application/json'); if (q.url.startsWith('/api/trend')) { const now = Date.now(); return s.end(JSON.stringify({ points: Array.from({ length: 1440 }, (_, i) => { const v = 14 + 9 * Math.sin(i / 90) + 5 * Math.sin(i / 7) + (i % 211 < 12 ? 38 : 0); return { t: now - (1440 - i) * 60000, v: Math.max(1, v), peak: Math.min(100, v + 12) }; }).filter((_, i) => i < 600 || i > 660) })); } if (q.url.startsWith('/api/ios-history')) { const file = new URL(q.url, 'http://x').searchParams.get('file'), now = Date.now(), told = JSON.parse(require('fs').readFileSync(require('path').join(__dirname, '..', 'whats-new.json'), 'utf8'))[file] || {}; return s.end(JSON.stringify({ builds: Object.keys(told).sort((x, y) => y - x).map((b, i) => ({ build: b, at: now - (i < 3 ? (2 + 3 * i) : 26 + 20 * i) * 3600000, notes: told[b] })) })); } if (q.url.startsWith('/api/term')) return s.end(JSON.stringify({ running: true, text: '╭─ Claude Code ─╮\n\n> fix the widget\n\n⏺ Updated widget.swift\n\n  Teach auto mode about your environment?\n  ❯ 1. Yes\n    2. Not now\n    3. Don\'t show again\n\n  Enter to confirm · Esc to cancel' })); if (q.url.startsWith('/api/files/recent')) { const now = Date.now(); return s.end(JSON.stringify({ folder: '~/Downloads/From iPhone', files: [['IMG_4126.HEIC', 2.9e6, 4], ['Boarding pass.pdf', 310e3, 52], ['apple.com.webloc', 240, 190], ['Shopping list.txt', 1.2e3, 1500], ['Trip.mov', 48e6, 4000], ['IMG_4101.HEIC', 3.1e6, 9000]].map(([name, size, min]) => ({ name, size, at: now - min * 60000, dir: false })) })); } if (q.url.startsWith('/api/mac/health')) { const p = [['tailscale', 'Running'], ['serve', 'https → bridge'], ['bridge', 'Answering'], ['sessions', '6 of 6 running'], ['tv', 'Connected'], ['letterboxd', 'Sign-in relay running'], ['chumby', 'Answering'], ['oclp', 'HEALTHY: macOS 26.7.2, OCLP 3.0.0'], ['stuck', 'Nothing stuck']]; return s.end(JSON.stringify({ ok: true, at: Date.now(), parts: p.map(([part, say]) => ({ part, state: 'ok', say })) })); } if (q.url.startsWith('/api/mac/prerestart')) { const p = [['oclp', 'Patches healthy'], ['updates', 'No macOS update will install'], ['filevault', 'Off; no password at boot'], ['autologin', 'Logs in by itself'], ['tailscale', 'Starts at login'], ['work', 'Nothing long-running'], ['keep', 'Scripts from /tmp kept in ~/.local/share/keep-after-reboot']]; return s.end(JSON.stringify({ ok: true, at: Date.now(), parts: p.map(([part, say]) => ({ part, state: 'ok', say })) })); } if (q.url === '/api/live' && live) return s.end(live()); s.end(q.url === '/api/status' ? status() : q.url === '/api/procs' ? macProcs : '{}'); };
http.createServer((q, s) => macRoutes(q, s, () => macStatus)).listen(9001, '127.0.0.1').on('upgrade', (q, k) => mockScreen(q, k));
// The same Mac with its readings changing every second, as the real one's do, for the films of a page pulled past
// its end and let go while readings land (Richard, 2026-11-08: "it doesnt bounce back naturally its like a sudden move
// back"): the CPU and memory figures, the history lines, a reading that's seldom there, and an app that comes and goes
// in Open on the Mac, so rows change height. Only on its own port: every other shot keeps the still Mac.
const liveMac = () => {
  const n = Math.floor(Date.now() / 1000), m = JSON.parse(macStatus);
  m.cpu.total = 8 + (n * 7) % 41; m.cpu.per = m.cpu.per.map((v, i) => 3 + ((n * 13 + i * 5) % 57));
  m.mem.used = 1.2e10 + ((n * 11) % 23) * 2e8;
  m.load = [0.8 + (n % 9) / 4, 1.1, 0.9];
  m.net.rxRate = 20000 + ((n * 17) % 61) * 3000; m.net.txRate = 4000 + ((n * 5) % 13) * 900;
  for (const k of Object.keys(m.hist)) { const h = m.hist[k]; h.push(h[(n + k.length) % h.length] * (0.7 + (n % 5) / 8)); h.shift(); }
  m.temps.forEach((t, i) => { t.c = Math.round(t.c + ((n * (i + 3)) % 7) - 3); });
  if (n % 2) m.apps.push({ name: 'TextEdit', pid: 18, cpu: 0, mem: 88000000 });
  if (n % 3 === 0) m.apps.splice(m.apps.findIndex(a => a.name === 'Music'), 1);
  return m;
};
const liveMacStatus = () => JSON.stringify(liveMac());
const liveMacLive = () => { const m = liveMac(); return JSON.stringify({ uptime: m.uptime, load: m.load, cpu: m.cpu, mem: m.mem, net: m.net, hist: m.hist, temps: m.temps, displayOn: m.displayOn }); };
http.createServer((q, s) => macRoutes(q, s, liveMacStatus, liveMacLive)).listen(9021, '127.0.0.1').on('upgrade', (q, k) => mockScreen(q, k));
// The same Mac under load (9031), as his was on 2026-11-11: every reading takes 2 to 5 s to come and every seventh
// never comes at all. The Mac is there the whole time, so the app must never say it can't reach it.
let slowReads = 0;
http.createServer((q, s) => {
  if (!/^\/api\/(live|status)/.test(q.url)) return macRoutes(q, s, liveMacStatus, liveMacLive);
  if (++slowReads % 7 === 0) return q.socket.destroy();
  setTimeout(() => macRoutes(q, s, liveMacStatus, liveMacLive), 2000 + (slowReads * 733) % 3000);
}).listen(9031, '127.0.0.1').on('upgrade', (q, k) => mockScreen(q, k));
// The Mac as his really reads (9041), for the films of Status at rest and pulled (Richard, 2026-11-11: "that same
// resizing issue in the mac pro app is still happening"): the shape of the bridge's own answers on a busy night (made-up
// values, nothing of his). Eight top processes whose names and order change with each reading, some long; network rates
// from a few KB/s to tens of MB/s, so a figure's width changes; 120-point histories; the uptime counting on; the health
// counted (healthBad 0); every reading 0.1 to 0.9 s late, as over Tailscale with the Mac loaded. Asked for at the phone's
// own pace (live every second, everything every 10 s), never faster.
const realBoot = Date.now() / 1000 - 49000;
const realNames = ['Claude Code', 'node', 'WindowServer', 'Google Chrome Helper (Renderer)', 'awk', 'sysmond', 'otool-classic', 'fileproviderd', 'mds_stores', 'Code Helper (Plugin)', 'kernel_task', 'swift-frontend'];
const realMac = () => {
  const now = Date.now() / 1000, n = Math.floor(now), m = JSON.parse(macStatus);
  m.uptime = Math.floor(now - realBoot);
  m.healthBad = 0;
  m.cpu.total = 80 + (n * 7) % 19; m.cpu.per = m.cpu.per.map((v, i) => 70 + ((n * 13 + i * 5) % 30));
  m.mem.used = 1.45e10 + ((n * 11) % 23) * 3e7; m.mem.total = 34359738368;
  m.load = [29 + (n % 9), 33.4, 28.3];
  const rx = [3477, 21907, 48427151, 159693, 6879, 628813, 12716515, 42351], tx = [2971, 746060, 17843, 311321, 4296, 819439, 9610, 148404];
  m.net.rxRate = rx[n % rx.length] * (0.9 + (n % 3) / 10); m.net.txRate = tx[(n * 3) % tx.length];
  for (const k of Object.keys(m.hist)) { const h = Array.from({ length: 120 }, (_, i) => { const j = n - 120 + i; return k === 'cpu' ? 80 + (j * 7) % 19 : k === 'mem' ? 43 + (j % 3) : (rx[(j * 5) % rx.length] / (k === 'tx' ? 9 : 1)); }); m.hist[k] = h; }
  m.temps = [['CPU', 81.7], ['GPU A', 62.9], ['GPU B', 63.1], ['Memory', 59.2], ['Chipset', 59], ['Drive', 52.1], ['Power supply', 63.8], ['Intake air', 30.6]].map(([name, c], i) => ({ name, c: Math.round((c + ((n * (i + 3)) % 5) * 0.4 - 0.8) * 10) / 10 }));
  m.procs = Array.from({ length: 8 }, (_, i) => { const name = realNames[(n * 5 + i * 7) % realNames.length]; return { pid: 1000 + ((n + i * 3) % 12), cpu: Math.round((24.8 - i * 2.6 + (n % 4)) * 10) / 10, mem: Math.round(((n + i) % 7) * 6) / 10, name }; });
  m.disk.used = 185245831168 + (n % 50) * 4e5; m.disk.free = 65544605696 - (n % 50) * 4e5; m.disk.total = 250790436864;
  m.at = n * 1000;
  return m;
};
const realLive = () => { const m = realMac(); return JSON.stringify({ uptime: m.uptime, load: m.load, cpu: m.cpu, mem: m.mem, net: m.net, hist: m.hist, temps: m.temps, displayOn: m.displayOn }); };
let realReads = 0;
http.createServer((q, s) => {
  if (!/^\/api\/(live|status)/.test(q.url)) return macRoutes(q, s, () => JSON.stringify(realMac()), realLive);
  setTimeout(() => macRoutes(q, s, () => JSON.stringify(realMac()), realLive), 100 + (++realReads * 373) % 800);
}).listen(9041, '127.0.0.1').on('upgrade', (q, k) => mockScreen(q, k));
// The same Mac behind his link's speed, for the Screen's first picture as he waits for it (2026-11-07).
http.createServer((q, s) => { if (q.url.startsWith('/ios/icon/')) return appIcon(q, s); s.setHeader('content-type', 'application/json'); s.end(q.url === '/api/status' ? macStatus : '{}'); }).listen(9011, '127.0.0.1').on('upgrade', (q, k) => mockScreen(q, k, true));
// A Mac that wants its access code, for the Mac Pro app's shot of the sign-in row.
http.createServer((q, s) => { s.statusCode = 401; s.setHeader('content-type', 'application/json'); s.end('{"error":"Sign in to the Mac Pro."}'); }).listen(9003, '127.0.0.1');
// And a sample TV for the TV app, with drawn pictures so banner crops, posters and the wall can be judged.
const zlib = require('zlib');
const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc = b => { let c = 0xffffffff; for (const x of b) c = crcTable[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (t, d) => { const n = Buffer.alloc(4), r = Buffer.alloc(4), b = Buffer.concat([Buffer.from(t), d]); n.writeUInt32BE(d.length); r.writeUInt32BE(crc(b)); return Buffer.concat([n, b, r]); };
const png = (w, h, a, b) => {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0, o = 0; y < h; y++) { o++; for (let x = 0; x < w; x++) { const t = (x / w + y / h) / 2; for (let c = 0; c < 3; c++) raw[o++] = a[c] + (b[c] - a[c]) * t; } }
  const head = Buffer.alloc(13); head.writeUInt32BE(w, 0); head.writeUInt32BE(h, 4); head[8] = 8; head[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', head), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
};
// Pictures drawn pixel by pixel (RGBA), for the box's photo on Status and a still of the TV's home screen: something that
// reads as the real thing in the build's shots, rather than a flat square (r18). Drawn here; nothing personal in them.
const paint = (w, h, at) => {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0, o = 0; y < h; y++) { o++; for (let x = 0; x < w; x++) { const p = at(x, y); for (let c = 0; c < 4; c++) raw[o++] = Math.max(0, Math.min(255, p[c])); } }
  const head = Buffer.alloc(13); head.writeUInt32BE(w, 0); head.writeUInt32BE(h, 4); head[8] = 8; head[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', head), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
};
const inRound = (x, y, x0, y0, w, h, r) => { const cx = Math.max(x0 + r, Math.min(x, x0 + w - r)), cy = Math.max(y0 + r, Math.min(y, y0 + h - r)); return (x - cx) ** 2 + (y - cy) ** 2 <= r * r && x >= x0 && x < x0 + w && y >= y0 && y < y0 + h; };
// A small black streaming box at a slight angle of light: soft top sheen, a status light at the front.
const boxPhoto = paint(320, 320, (x, y) => {
  if (inRound(x, y, 50, 70, 220, 200, 34)) {
    const sheen = Math.max(0, 1 - (y - 70) / 90) * 46, edge = inRound(x, y, 54, 74, 212, 192, 30) ? 0 : 22;
    if ((x - 160) ** 2 + (y - 250) ** 2 < 16) return [255, 255, 255, 230];
    return [14 + sheen + edge, 14 + sheen + edge, 16 + sheen + edge, 255];
  }
  // Its shadow on the table.
  const d = ((x - 160) / 130) ** 2 + ((y - 282) / 18) ** 2;
  return d < 1 ? [0, 0, 0, Math.round(90 * (1 - d))] : [0, 0, 0, 0];
});
// The launcher's home screen: a wide recommendation row, then two rows of app banners, on its dark ground.
const homeTiles = [[[190, 50, 40], [70, 20, 60]], [[40, 120, 190], [20, 40, 90]], [[220, 170, 60], [140, 60, 30]], [[40, 160, 120], [20, 60, 70]]];
const appTiles = [[230, 30, 30], [20, 20, 20], [124, 77, 255], [245, 245, 245], [15, 15, 15], [229, 9, 20], [229, 160, 13], [30, 30, 30]];
const homeStill = paint(960, 540, (x, y) => {
  const bg = [18 + y / 30, 22 + y / 30, 30 + y / 24, 255];
  for (let i = 0; i < 4; i++) {
    const x0 = 60 + i * 215, y0 = 70;
    if (x >= x0 && x < x0 + 200 && y >= y0 && y < y0 + 200 && inRound(x, y, x0, y0, 200, 200, 8)) {
      const [a, b] = homeTiles[i], t = (y - y0) / 200; return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, 255];
    }
  }
  for (let r = 0; r < 2; r++) for (let i = 0; i < 4; i++) {
    const x0 = 60 + i * 215, y0 = 300 + r * 105;
    if (inRound(x, y, x0, y0, 200, 92, 6)) { const c = appTiles[r * 4 + i]; return [c[0], c[1], c[2], 255]; }
  }
  return bg;
});
const pictures = { wide: png(284, 160, [200, 40, 60], [240, 150, 40]), square: png(160, 160, [230, 230, 240], [120, 200, 240]), poster: png(234, 352, [40, 70, 120], [220, 120, 70]), art: png(300, 300, [190, 40, 120], [30, 90, 200]) };
const tvBase = 'http://127.0.0.1:9002';
const tvApps = [['com.codex.musicwebtv', 'Mint Music', 1], ['com.mint.letterboxd', 'Letterboxd', 1], ['com.stremio.one', 'Stremio', 1], ['com.google.android.youtube.tv', 'YouTube', 1], ['com.google.android.youtube.tvmusic', 'YouTube Music', 1], ['com.netflix.ninja', 'Netflix', 1], ['com.plexapp.android', 'Plex', 1], ['com.apple.atve.androidtv.appletv', 'Apple TV', 1], ['com.android.tv.settings', 'Settings', 1], ['com.google.android.play.games', 'Google Play Games', 1], ['flar2.homebutton', 'Button Mapper', 1]];
const tvStatus = JSON.stringify({ online: true, screen: 'on', app: 'com.stremio.one', volume: 12, volumeMax: 25,
  music: { title: 'Sample Song', artist: 'Sample Artist', album: 'Sample Album', art: tvBase + '/art.png', playing: true, position: 40000, duration: 180000, sampledAt: Date.now() },
  apps: tvApps.map(([pkg, name, wide]) => ({ pkg, name, hasIcon: true, wide: !!wide })) });
const film = (t, more) => ({ film_slug: t.toLowerCase().replace(/[ ,]+/g, '-'), film_title: t, film_year: '1971', poster_url: tvBase + '/poster.png', ...more });
const tvFilms = JSON.stringify({ signedIn: true,
  watchlist: ['Dirty Harry', 'Chinatown', 'Heat', 'Alien', 'Ran', 'Klute', 'Thief', 'Le Samourai'].map(t => film(t, { friends_count: '4', friends_rating_avg: '3.5' })),
  friends: ['Battle Heater', 'Paris, Texas', 'Ran', 'Vertigo', 'Stalker', 'Tampopo', 'Ikiru', 'Paris, Texas'].map(t => film(t, { friend_name: 'a friend', rating: '4.0' })) });
const tvMint = JSON.stringify({ rows: ['Recently played', 'Made for you', 'New releases'].map(title => ({ title, items: ['Sample Album', 'Another Album', 'Third Album', 'Fourth Album'].map(t => ({ title: t, subtitle: 'Sample Artist', art: tvBase + '/art.png', id: 'https://music.apple.com/us/album/' + title + t, kind: 'album' })) })) });
// Continue watching leads with a YouTube video left half-watched on the TV, as the Mac sends it (kind youtube, a wide still,
// the second to resume from), ahead of Stremio's own.
const tvYouTubeCard = { title: 'A sample video that goes on a bit', subtitle: '1 h 20 min left · Sample Channel', art: tvBase + '/api/tv/shot', id: 'dQw4w9WgXcQ', kind: 'youtube', resume: 754, progress: 0.4 };
const tvStremio = JSON.stringify({ rows: ['Continue watching', 'Popular movies', 'Popular series'].map(title => ({ title, items: [...(title === 'Continue watching' ? [tvYouTubeCard] : []), ...['Heat', 'Alien', 'Chinatown', 'Thief', 'Collateral', 'Ronin', 'Sorcerer'].map((t, n) => ({ title: t, subtitle: title === 'Continue watching' ? `Continue · ${85 - 11 * n}m left` : '1995 · ★ 8.3', art: tvBase + '/poster.png', id: (title === 'Popular series' ? 'tt123456' : 'tt765432') + n, kind: title === 'Popular series' ? 'series' : 'movie', progress: title === 'Continue watching' ? +(1 - (85 - 11 * n) / 170).toFixed(3) : t === 'Alien' ? 0.4 : undefined, about: 'A sample description of the film.' }))] })) });
// A TV with a player open, for the shots of what the app shows then. Asked for by putting /stremio or /youtube in front
// of the address, so every other shot gets the same answers as before.
const tvScene = scene => {
  const v = JSON.parse(tvStatus), now = Date.now();
  if (scene === 'stremio') { v.app = 'com.stremio.one'; v.session = { pkg: 'com.stremio.one', playing: true, description: ['Sample Series', 'S1E2 Episode 2'], position: 1260000, sampledAt: now, duration: 3480000, canSeek: true, art: tvBase + '/poster.png' }; }
  // A film nearly over, for Start over and for skips still on their way.
  if (scene === 'ending') { v.app = 'com.stremio.one'; v.session = { pkg: 'com.stremio.one', playing: true, description: ['Heat'], position: 7600000, sampledAt: now, duration: 8000000, canSeek: true, art: tvBase + '/poster.png' }; }
  // The Mac looks a YouTube video up by its title and sends its still as the session's art, and its length.
  if (scene === 'youtube') { v.app = 'com.google.android.youtube.tv'; v.session = { pkg: 'com.google.android.youtube.tv', playing: true, description: ['A sample video', 'Sample Channel'], position: 95000, sampledAt: now, duration: 600000, canSeek: false, art: tvBase + '/api/tv/shot' }; }
  return JSON.stringify(v);
};
http.createServer((q, s) => {
  // Frames the app took longer than 34 ms to draw, in any scene, kept for the build (r21: stalls as numbers).
  if (q.method === 'POST' && /\/api\/tv\/hitch$/.test(q.url)) {
    let body = ''; q.on('data', c => body += c);
    q.on('end', () => { try { for (const h of JSON.parse(body).hitches || []) require('fs').appendFileSync('/tmp/tv-hitches.log', `${new Date(h.at).toISOString()} ${h.note ? 'ASSERT ' + h.note : h.mark ? 'MARK ' + h.mark : h.ms + ' ms'}\n`); } catch {} s.setHeader('content-type', 'application/json'); s.end('{"ok":true}'); });
    return;
  }
  if (tvPose(q, s)) return;
  const scene = (q.url.match(/^\/(stremio|youtube|ending)(?=\/)/) || [])[1];
  if (scene) q.url = q.url.slice(scene.length + 1);
  if (scene && q.url === '/api/tv/status') { s.setHeader('content-type', 'application/json'); return s.end(tvScene(scene)); }
  // Skips take the real player a few seconds, so the shot catches them still on their way.
  if (scene && q.method === 'POST' && q.url === '/api/tv/player-seek') { s.setHeader('content-type', 'application/json'); return setTimeout(() => s.end(JSON.stringify({ ok: true, position: 7630000, duration: 8000000 })), 6000); }
  if (q.url.startsWith('/api/tv/mint')) {
    s.setHeader('content-type', 'application/json');
    // A search only answers with what matches it, as the real bridge does; the plain list otherwise.
    const want = (new URL(q.url, 'http://x').searchParams.get('q') || '').trim().toLowerCase();
    if (!want) return s.end(tvMint);
    const all = JSON.parse(tvMint), seen = new Set();
    const items = (all.rows || []).flatMap(r => r.items || []).filter(i => (i.title + ' ' + (i.subtitle || '')).toLowerCase().includes(want) && !seen.has(i.id) && seen.add(i.id));
    return s.end(JSON.stringify({ rows: items.length ? [{ title: 'Music', items }] : [] }));
  }
  if (q.url.startsWith('/api/tv/streams')) { s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify({ streams: [['1080p', '1080p', 3.2, ''], ['1080p', '1080p', 1.4, ''], ['4K HDR', '4K', 18.4, 'HDR'], ['720p', '720p', 0.9, '']].map(([name, quality, gb, hdr], n) => ({ token: 's' + n, addon: 'Sample addon', name, description: 'Sample.Film.2024.' + quality + '.WEB-DL.x264', quality, hdr, gb, instant: n < 3 })) })); }
  if (q.url.startsWith('/api/tv/discover')) {
    s.setHeader('content-type', 'application/json');
    // A search of the catalogue answers as the real one does: one "Results" list of that kind (films or shows), the
    // titles that hold the words. The Apps page's search asks this for films and for shows.
    const u = new URL(q.url, 'http://x'), term = (u.searchParams.get('q') || '').trim().toLowerCase();
    if (!term) return s.end(tvStremio);
    const series = u.searchParams.get('type') === 'series', seen = new Set();
    const hits = JSON.parse(tvStremio).rows.flatMap(r => r.items).filter(i => (i.kind === 'series') === series && i.kind !== 'youtube' && i.title.toLowerCase().includes(term) && !seen.has(i.title) && seen.add(i.title));
    return s.end(JSON.stringify({ rows: hits.length ? [{ title: 'Results', items: hits }] : [] }));
  }
  if (q.url.startsWith('/api/tv/stremio-meta')) { s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify({ about: 'A sample series, for the screenshot.', episodes: [1, 2, 3, 4].flatMap(n => [1, 2].map(season => ({ id: 'tt1234567:' + season + ':' + n, season, episode: n, name: n % 2 ? 'Episode ' + n : 'Episode ' + n + ': The One Where Everybody Finally Comes Home for the Long Weekend', thumb: tvBase + '/still.png', runtime: 21 + (n % 3), overview: 'A made-up afternoon goes sideways when the family visits.' }))) })); }
  // Mint's own screen for the song on: its words, timed, and what plays after it (the Playing tab mirrors both).
  if (q.url.startsWith('/api/tv/music-detail')) {
    s.setHeader('content-type', 'application/json');
    const words = ['The first line of a sample song', 'A second line that runs a little longer than the first', '', 'Here the chorus comes around', 'And says the same thing twice', 'And says the same thing twice', 'A quiet line', 'The last line of a sample song'];
    return s.end(JSON.stringify({ ok: true, title: 'Sample Song', artist: 'Sample Artist', album: 'Sample Album', playing: true, position_ms: 40000, duration_ms: 180000, airplay: false, asked_at: Date.now(),
      lyrics: { status: '', synced: true, line: 3, lines: words.map((w, i) => [25000 + i * 5000, 30000 + i * 5000, w]) },
      queue: { remaining: 7, items: ['Next Song', 'Another Song', 'Third Song'].map(title => ({ title, artist: 'Sample Artist', album: 'Sample Album', duration_ms: 200000, art: tvBase + '/art.png' })) } }));
  }
  if (q.url.startsWith('/api/tv/recs')) { s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify({ films: ['Rope', 'Match Point', 'Blue Velvet', 'Klute'].map(title => ({ title, year: '1990', slug: title.toLowerCase(), imdb: 'tt1234567', art: tvBase + '/poster.png', why: 'Because you liked Heat' })) })); }
  // A search for the show on the TV finds it, as the real catalogue would (the app looks a series up by name when its
  // rows don't carry it).
  if (q.url.startsWith('/api/tv/stremio') && /sample\+?%20?series|sample series/i.test(decodeURIComponent(q.url.replace(/\+/g, ' ')))) {
    s.setHeader('content-type', 'application/json');
    return s.end(JSON.stringify({ rows: [{ title: 'Series', items: [{ title: 'Sample Series', subtitle: '2 seasons', art: tvBase + '/poster.png', id: 'tt1234567', kind: 'series' }] }] }));
  }
  // The app says Continue watching is on screen (r27: asked for, but never applied, open).
  if (q.url.startsWith('/api/tv/applied')) { try { require('fs').appendFileSync('/tmp/tv-home-applied.log', Date.now() + ' ' + q.url + '\n'); } catch {} s.setHeader('content-type', 'application/json'); return s.end('{"ok":true}'); }
  if (q.url.startsWith('/api/tv/stremio')) {
    // Logged, so CI can assert the Watch tab really asked for Stremio's home (r26: open, Continue watching never loaded).
    try { require('fs').appendFileSync('/tmp/tv-home-fetches.log', Date.now() + ' ' + q.url + '\n'); } catch {}
    s.setHeader('content-type', 'application/json'); return s.end(tvStremio);
  }
  if (q.url === '/api/tv/device-image') { s.setHeader('content-type', 'image/png'); return s.end(boxPhoto); }
  if (q.url === '/api/tv/device') { const up = [12, 18, 9, 22, 30, 14, 11, 16, 25, 19]; s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify({ model: 'onn. 4K Streaming Box', android: '14', resolution: '1920x1080', wifi: 'Home Wi-Fi', ip: '192.168.1.2', uptime: 122000, cpu: 18, memUsed: 1.4e9, memTotal: 2e9, diskUsed: 3.3e9, diskTotal: 4.7e9, tempC: 46, rxRate: 2.4e6, txRate: 8e4, hist: { cpu: up, mem: up.map(x => x + 50), rx: up, tx: up } })); }
  // The TV's home screen, for the stage's TV and the Remote's still (shot.jpg was a photo of a Chumby).
  if (q.url === '/api/tv/shot') { s.setHeader('content-type', 'image/png'); return s.end(homeStill); }
  // The apps' real banners wherever the repo has them (ci/tv-icons), so every scene shows what his TV shows, never a
  // made-up gradient a fallback has to stand in for (r17: text-only tiles on the open Remote).
  if (q.url.startsWith('/api/tv/icon')) {
    s.setHeader('content-type', 'image/png');
    const pkg = new URL(q.url, 'http://x').searchParams.get('pkg') || '', file = __dirname + '/tv-icons/' + pkg + '.png';
    if (/^[\w.]+$/.test(pkg) && require('fs').existsSync(file)) return s.end(require('fs').readFileSync(file));
    const a = tvApps.find(x => x[0] === pkg); return s.end(a && a[2] ? pictures.wide : pictures.square);
  }
  // Sending to the TV takes a moment there, so the waiting can be seen.
  if (q.method === 'POST' && /play-stream|stremio-open|mint-open/.test(q.url)) { s.setHeader('content-type', 'application/json'); return setTimeout(() => s.end('{"ok":true}'), 3000); }
  if (q.url === '/poster.png' || q.url === '/art.png') { s.setHeader('content-type', 'image/png'); return s.end(pictures[q.url.slice(1, -4)]); }
  // An episode's own still, wide as a real one is (the episodes' rows, the Remote's and Playing's picture of one).
  if (q.url === '/still.png') { s.setHeader('content-type', 'image/png'); return s.end(pictures.wide); }
  s.setHeader('content-type', 'application/json');
  s.end(q.url === '/api/tv/status' ? tvStatus : q.url === '/api/tv/letterboxd' ? tvFilms : '{"ok":true}');
}).listen(9002, '127.0.0.1');

// ---- Chumby app poses (separate block) -------------------------------------------------------------------------------
// Asked for by a path in front of the address (http://127.0.0.1:9000/ringing and so on), so every shot above gets the same
// answers as before. Anything a scene doesn't change falls through to the answers above.
// Pandora's history, for "Woke up to": songs just after the Weekend alarm (9:30) on the last two weekend mornings.
{
  const songs = [], d = new Date();
  for (let back = 1; songs.length < 4 && back < 14; back++) {
    const day = new Date(d.getFullYear(), d.getMonth(), d.getDate() - back, 9, 30);
    if (day.getDay() !== 0 && day.getDay() !== 6) continue;
    const t = day.getTime() / 1000;
    // A different first song each morning, as Pandora plays it: the same one twice read as a duplicate tile (r27).
    const first = songs.length ? { title: 'Freddie Freeloader', artist: 'Miles Davis', album: 'Kind of Blue' } : { title: 'So What', artist: 'Miles Davis', album: 'Kind of Blue' };
    songs.push({ t: t + 70, ...first }, { t: t + 640, title: 'Take Five', artist: 'The Dave Brubeck Quartet', album: 'Time Out' });
  }
  // The Chumby's ring log: each weekend morning's ring, and a once-only calendar alarm from yesterday afternoon, which is
  // no longer in the alarm list, with its song: Woke up to must pair it from the log (2026-11-06: "woke up to doesnt work").
  const rings = songs.filter((x, i) => i % 2 === 0).map(x => ({ t: x.t - 70, name: 'Weekend' }));
  const cal = new Date(d.getFullYear(), d.getMonth(), d.getDate() - 1, 14, 40).getTime() / 1000;
  songs.push({ t: cal + 10, title: 'Save Tonight', artist: 'Eagle-Eye Cherry', album: 'Desireless' });
  rings.push({ t: cal, name: 'Calendar: Shift' });
  data.hist = { ok: true, songs: songs.sort((x, y) => y.t - x.t), rings: rings.sort((x, y) => y.t - x.t) };
}
// The live scenes keep what's saved and what's ringing, for the films of Snooze, Stop and a nap set and cancelled.
const chumbyLive = { live: { sys: { ...data.sys, ring: '' }, state: JSON.parse(JSON.stringify(data.state)) },
  liveringing: { sys: { ...data.sys, ring: 'r\tWork\tBeep' }, state: JSON.parse(JSON.stringify(data.state)) } };
// The next Work alarm (6:45 on a weekday), as the Chumby names a skipped one.
function nextWork() {
  const d = new Date();
  for (let i = 0; i < 8; i++) {
    const t = new Date(d.getFullYear(), d.getMonth(), d.getDate() + i, 6, 45);
    if (t > d && t.getDay() !== 0 && t.getDay() !== 6) return { name: 'Work', at: t.getTime() / 1000, when: 'weekday' };
  }
}
const songScene = { at: 0 };
// An alarm's next ring at or after `from` (ms), as the panel works it out, or null.
function nextRing(a, from) {
  if (a.enabled !== '1') return null;
  if (a.when === 'once') { const t = +a.time * 60000; return t >= from ? t : null; }
  const days = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'], d0 = new Date(from);
  for (let i = 0; i < 9; i++) {
    const d = new Date(d0.getFullYear(), d0.getMonth(), d0.getDate() + i, Math.floor(+a.time / 60), +a.time % 60), w = d.getDay();
    if (d.getTime() < from) continue;
    if (a.when === 'daily' || (a.when === 'weekday' && w > 0 && w < 6) || (a.when === 'weekend' && (w === 0 || w === 6)) || a.when === days[w]) return d.getTime();
  }
  return null;
}
// The skip a=skip name=&at= leaves: that alarm's next ring, if it's at or after `at` (epoch minutes; now when 0).
function pinned(state, name, at) {
  const from = Math.max(Date.now(), at * 60000);
  for (const a of state.alarms) {
    if (a.name !== name) continue;
    const t = nextRing(a, Date.now());
    if (t !== null && t >= from - 59999) return { name, at: Math.floor(t / 60000) * 60, when: a.when };
  }
  return null;
}
// What do_save writes, given the list it held: never the stock backup beeper; every "Calendar: " alarm with the shared
// calendar set (tpl=I makes alarm I's the set) unless sent with I_own=1, which keeps what was sent and comes back with
// own="1" (chumby 2c90cc9; every other alarm reads own=""); one copy per name, repeat and time (the one that's on, then the later);
// and Rick's newest_wins: an alarm that's on and wasn't in the saved list (by name|when|time) turns every other alarm
// off, Calendar, Catch-up and Nap alarms apart. So switching on one already in the list is a plain toggle.
const TPL_KEYS = ['type', 'arg', 'param', 'param_description', 'duration', 'snooze', 'auto_dismiss', 'action', 'action_param', 'backup', 'backupDelay'];
function kept(state, f) {
  const n = +f.get('n') || 0, sent = Array.from({ length: n }, (_, i) => Object.fromEntries(ALARM_KEYS.map(k => [k, f.get(i + '_' + k) || ''])));
  const isCal = a => a.name.startsWith('Calendar: '), helper = a => a.name === 'Catch-up' || a.name === 'Nap', key = a => a.name + '|' + a.when + '|' + a.time;
  if (f.has('tpl')) state.calTpl = { ...Object.fromEntries(TPL_KEYS.map(k => [k, sent[+f.get('tpl')][k]])), name: '', enabled: '', time: '', when: '', own: '' };
  const old = new Set(state.alarms.map(key)), counts = a => a.enabled === '1' && !helper(a) && !isCal(a);
  const added = sent.map(a => counts(a) && !old.has(key(a)));
  const any = added.some(Boolean);
  const out = sent.map((a, i) => {
    const own = isCal(a) && a.own === '1';
    const b = { ...a, ...(isCal(a) && !own && state.calTpl ? Object.fromEntries(TPL_KEYS.map(k => [k, state.calTpl[k]])) : {}), backup: '0', own: own ? '1' : '' };
    if (!/^\d+$/.test(b.backupDelay) || +b.backupDelay > 120) b.backupDelay = '5';
    if (any && counts(a) && !added[i]) b.enabled = '0';
    return b;
  });
  return out.filter((a, i) => !out.some((b, j) => j !== i && key(b) === key(a) && (b.enabled === '1' && a.enabled !== '1' || (j > i && (b.enabled === '1') === (a.enabled === '1')))));
}
function chumbyScene(q, s) {
  const a = new URL(q.url, 'http://x').searchParams.get('a');
  // A real 320 x 240 capture from the Chumby on every Chumby shot, so the hero can be judged.
  const shot = () => { s.setHeader('content-type', 'image/jpeg'); s.end(require('fs').readFileSync(__dirname + '/chumby-screen.jpg')); return true; };
  if (a === 'shot' && !/^\/slow\//.test(q.url)) return shot();
  const m = q.url.match(/^\/(ringing|snoozed|dead|slow|fail|live|liveringing|skipped|playing|night|songchange|orphan|moved|nap)\//);
  if (!m) return false;
  const scene = m[1];
  const json = v => { s.setHeader('content-type', 'application/json'); s.end(JSON.stringify(v)); return true; };
  if (chumbyLive[scene]) {
    const live = chumbyLive[scene];
    if (q.method === 'POST') {
      let body = '';
      q.on('data', c => body += c);
      q.on('end', () => {
        const qs = new URL(q.url, 'http://x').searchParams, f = new URLSearchParams(body);
        if (a === 'cmd' && qs.get('c') === 'ringsnooze') live.sys.ring = live.sys.ring.replace(/^r/, 's');
        if (a === 'cmd' && qs.get('c') === 'ringoff') live.sys.ring = '';
        // The panel's own skip, as the Chumby answers it: pinned by name (and the ring at or after `at`, epoch minutes)
        // since chumby 2c90cc9, an unknown name leaving no skip; without a name, the next Work. One pin only: a new skip
        // replaces it. (The hook's same-minute rule, a second copy due that minute skipped too, applies only to a copy
        // with the same name; the mock never rings, so there's nothing more to it here.)
        if (a === 'skip') {
          const name = qs.get('name');
          if (name !== null && (name.length > 64 || /[\x00-\x1f]/.test(name))) return json({ ok: false, error: 'bad name' });
          if (qs.get('at') !== null && !/^\d+$/.test(qs.get('at'))) return json({ ok: false, error: 'bad at' });
          live.state.skipped = name ? pinned(live.state, name, +(qs.get('at') || 0)) : nextWork();
          return json({ ok: true, pending: false, skipped: live.state.skipped });
        }
        if (a === 'unskip') { live.state.skipped = null; return json({ ok: true, pending: false, skipped: null }); }
        // "Just this once" in one request, as the Chumby answers it (chumby 9d3c1a1): the one-off joins the list switched
        // on, any earlier one by that name replaced, no other alarm touched, and the skip is pinned to the usual ring.
        if (a === 'once') {
          const name = f.get('name') || '', at = +f.get('at'), to = +f.get('to'), oname = f.get('oname') || '';
          if (!/ \(just this once\)$/.test(oname) || / \(just this once\)$/.test(name)) return json({ ok: false, error: 'bad name' });
          if (!(at > 0 && to >= at && to <= at + 720)) return json({ ok: false, error: 'bad time' });
          const orig = live.state.alarms.find(x => x.name === name && x.enabled === '1');
          if (!orig) return json({ ok: false, error: 'no such alarm' });
          const one = { ...orig, name: oname, enabled: '1', when: 'once', time: String(to), backup: '0', backupDelay: '5', own: '' };
          if (f.get('type') !== null) for (const k of ['type', 'arg', 'param', 'param_description', 'duration', 'snooze', 'auto_dismiss']) one[k] = f.get(k) || '';
          live.state.alarms = [...live.state.alarms.filter(x => x.name !== oname), one];
          live.state.skipped = pinned(live.state, name, at);
          return json({ ok: true, confirmed: live.state.skipped !== null, pending: false, skipped: live.state.skipped });
        }
        // A Pandora station from its share link: the answer comes at once, the result in the state.
        if (a === 'pstation') {
          const id = ((f.get('u') || '').match(/station\/play\/(\d+)/) || [])[1], k = f.get('k') || '';
          live.state.pandoraAdd = id ? `${k}\tok\t${id}\tDream Pop Radio` : `${k}\terr\tthat link isn't a Pandora station`;
          if (id) live.state.pandora = [...live.state.pandora.filter(p => p.id !== id), { id, name: 'Dream Pop Radio' }];
          return json({ ok: true, pending: true });
        }
        // A channel chosen in the app stays chosen, so the channel shown doesn't snap back on the next reading.
        if (a === 'cmd' && qs.get('c') === 'channel') { live.state.channel = qs.get('v'); live.sys.chan = qs.get('v'); }
        if (a === 'save') {
          const why = saveProblem(f);
          if (why) return json({ ok: false, error: why });
          live.state.alarms = kept(live.state, f);
          live.state.volume = +f.get('v'); live.state.fade = +f.get('f');
        }
        json({ ok: true });
      });
      return true;
    }
    // The live scene's readings move as the real Chumby's do (its uptime, load, free memory and Wi-Fi), so a reading
    // changes Home's status rows every poll, as on his phone: the film of Home pulled past its end (chumby-homepull-
    // portrait) must show every one of them held while the page is past its end, not landing under the pull.
    if (a === 'sys') { const n = Math.floor(Date.now() / 1000); return json(scene === 'live' ? { ...live.sys, up: live.sys.up + n % 100000, load: 0.3 + (n % 7) / 10, memFree: live.sys.memFree - (n % 5) * 400, wifi: 60 + (n * 7) % 31 } : live.sys); }
    if (a === 'state') return json(stateNow(live.state));
    return false;
  }
  if (scene === 'slow') {
    // The first run, before anything has come back: nothing answers for half a minute.
    setTimeout(() => { if (a === 'shot') return shot(); if (data[a]) return json(data[a]); s.statusCode = 404; s.end(); }, 30000);
    return true;
  }
  if (a === 'shot') return shot();
  // Work rings with Beep, so that's what the card says.
  if (scene === 'ringing' && a === 'sys') return json({ ...data.sys, ring: 'r\tWork\tBeep' });
  if (scene === 'snoozed' && a === 'sys') return json({ ...data.sys, ring: 's\tWork\tBeep' });
  if (scene === 'skipped' && a === 'state') return json({ ...stateNow(data.state), skipped: nextWork() });
  // Work moved for one ring by "just this once": its one-off ten minutes after the usual time, the Chumby's skip pinned
  // to the usual ring.
  if (scene === 'moved' && a === 'state') {
    const w = nextWork();
    return json({ ...stateNow(data.state), skipped: w, alarms: [...data.state.alarms, alarm({ name: 'Work (just this once)', when: 'once', time: String(Math.floor(w.at / 60) + 10), backupDelay: '5' })] });
  }
  // A "just this once" for Work, ten minutes after its usual ring, with the Chumby's skip no longer on that ring: both
  // would ring, which the app says plainly with the two ways back.
  if (scene === 'orphan' && a === 'state') {
    const w = nextWork();
    return json({ ...stateNow(data.state), skipped: null, alarms: [...data.state.alarms, alarm({ name: 'Work (just this once)', when: 'once', time: String(Math.floor(w.at / 60) + 10), backupDelay: '5' })] });
  }
  // The panel's own report of the ring in a=state too, as the real one gives it beside a=sys "ring".
  if (scene === 'ringing' && a === 'state') return json({ ...stateNow(data.state), ringing: { state: 'ringing', name: 'Work', sound: 'Beep', until: 0 } });
  if (scene === 'snoozed' && a === 'state') return json({ ...stateNow(data.state), ringing: { state: 'snoozing', name: 'Work', sound: 'Beep', until: 0 } });
  // A Pandora wake-up 5 minutes ago with no song logged yet; 8 s into the scene the Chumby's state names the first song,
  // so "Woke up to" (Sounds) must gain its tile live.
  if (scene === 'songchange' && a === 'state') {
    songScene.at ||= Date.now();
    const now = Date.now() / 1000, fire = Math.floor(now / 60) - 5;
    const wake = alarm({ name: 'Wake', time: String(fire), when: 'once', type: 'audio', arg: 'pandora', param: '1', param_description: 'Morning Mix' });
    const song = Date.now() - songScene.at > 8000 ? { t: fire * 60 + 40, title: 'Take Five', artist: 'The Dave Brubeck Quartet', album: 'Time Out' } : null;
    // The wake-up's music is still playing, so Now and Woke up to tell the same story.
    return json({ ...stateNow(data.state), alarms: [...data.state.alarms, wake], song, music: { source: 'pandora', label: 'Pandora Radio', state: 'playing', playing: true } });
  }
  // A nap set 20 minutes from now, as the app's chips or Control Center leave it: the one "Nap" one-off, a short Beep.
  if (scene === 'nap' && a === 'state') {
    return json({ ...stateNow(data.state), alarms: [...data.state.alarms, alarm({ name: 'Nap', when: 'once', time: String(Math.floor(Date.now() / 60000) + 20), duration: '5' })] });
  }
  // Pandora playing a song it started a minute and a half ago, for Sounds' Now.
  if (scene === 'playing' && a === 'state') return json({ ...stateNow(data.state), music: { source: 'pandora', label: 'Pandora Radio', state: 'playing', playing: true } });
  // Night mode on, for Home's day/night pill lit as Night.
  if (scene === 'night' && a === 'sys') return json({ ...data.sys, night: 1 });
  if (scene === 'playing' && a === 'hist') return json({ ok: true, songs: [{ t: Date.now() / 1000 - 90, title: 'Blue in Green', artist: 'Miles Davis', album: 'Kind of Blue' }, ...data.hist.songs] });
  if (scene === 'dead') {
    // The Mac answers, but says the Chumby itself hasn't for 25 minutes.
    if (a === 'health') return json({ up: false, lastSeen: Date.now() / 1000 - 25 * 60 });
    if (a === 'sys' || a === 'state' || a === 'chlist') { s.statusCode = 502; s.end(); return true; }
  }
  // Every save turned down, the way a full Chumby turns one down.
  if (scene === 'fail' && q.method === 'POST') return json({ ok: false, error: 'bad count' });
  return false;
}

// ---- TV app poses (separate block) -----------------------------------------------------------------------------------
// Real assets where the sample pictures hid misses: the TV's own banners (one of them, YouTube Music's, really is a white
// logo on white, which the app must never show as it is), and the Watch tab's rows as the bridge really sends them, with
// the personal rows swapped for public titles. Then scenes asked for by a path in front of the address:
//   /tour         Mint playing, its cover changing every 5 s, so a tab tour shows whether the art behind each page keeps up.
//   /flickstream  A stream flick end to end: play-stream takes about 6 s and reports each step as a line of NDJSON, while
//                 the status goes from the home screen to Stremio open, its player paused, then playing.
//   /blankbanner  YouTube Music's banner as it once came from the Mac, white on white, to show the app's drawn one.
//   /cold         Status as the real box first answers after a quiet spell: no CPU reading, nothing moving, no history.
//   /rasleep /roffline /ryoutube /rmint /ridle /repisode
//                 The Remote's states: the TV asleep, the TV not answering, a YouTube video playing, Mint's music only,
//                 nothing on (the home screen), and a Stremio episode part way through.
//   /rfilm /rjoin /rstall
//                 The live picture's own states: a Stremio film playing with its poster (the stream stops for it); joining
//                 a recording under way, as the bridge does it (headers at once, then after 1.2 s everything since the last
//                 key frame in one write, counted in x-replay-frames, then 30 a second), on the home screen; and a
//                 stream that answers and never sends a picture, with no still to be had either, on the home screen.
//   /fnormal /fslow /ffail /foffline /falready /fbridgeon /fjoined
//                 The flick's starts (tv-iphone.md §2.5a): play-stream as NDJSON with each step's time since the request
//                 (awake 0, sent 120, player 2000, playing 3200); slow (playing at 9 s); failing (two fallbacks retried,
//                 then failed:"start"); the TV not answering for 2 s; and the film already playing on the TV, where nothing
//                 may be sent. Status carries starting and lastStart, prepare answers {ok, awake, fresh}, and every send is
//                 logged to /tmp/tv-flick-sends.log (GET /<scene>/reset clears it). bridgeon: the bridge finds it already
//                 on and answers {ok, alreadyOn} at once; joined: the answer carries joined:true. Both are plain successes.
//   /real         The real bridge's quirks, not the sample's perfect answers (Richard, 2026-11-05: bugs on his TV never
//                 showed here). A Stremio episode playing from 0:00 with no length for its first 20 s, then the catalogue's
//                 rounded 26 min against a real 21:55 (put right by the first seek); Mint's paused song still listed beside
//                 it; status answers 0.3–0.9 s late, every seventh 2 s; play and pause reaching the status 2.2 s after the
//                 key; a stream send taking about 12 s across its steps and starting the episode over; the playing show
//                 in Continue watching; a Stremio home of short rows; and the TV not answering from 30 to 35 s in. Every
//                 send to the TV is logged to /tmp/tv-real-sends.log, so a flow that must not re-send can be checked.
// And /api/tv/screen-live, a short canned H.264 stream of a drawn home screen, sent at 30 frames a second, looping.
function tvPose(q, s) {
  const fs = require('fs');
  const json = v => { s.setHeader('content-type', 'application/json'); s.end(typeof v === 'string' ? v : JSON.stringify(v)); return true; };
  const scene = (q.url.match(/^\/(tour|flickstream|blankbanner|cold|rtvoff|rtvawayfilm|rtvaway|rcecoff|rasleep|roffline|ryoutubebare|ryoutube|rmint|ridle|repisode|rfilm|rjoin|rstall|realscrub|real|live|fnormal|fslow|ffail|foffline|falready|fbridgeon|fjoined)(?=\/)/) || [])[1];
  if (scene) q.url = q.url.slice(scene.length + 1);
  const path = q.url.split('?')[0], query = new URL(q.url, 'http://x').searchParams;
  if (scene === 'real') { tvReal.known = false; return tvReal(q, s, path, query, json); }
  // The real scene with the episode's length known from the start, for the shot of a drag along the bar with its bubble.
  if (scene === 'realscrub') { tvReal.known = true; return tvReal(q, s, path, query, json); }
  if (/^f(normal|slow|fail|offline|already|bridgeon|joined)$/.test(scene || '')) return tvFlickStart(scene.slice(1), q, s, path, json);
  // The prepare call's answer everywhere else too, in the bridge's own shape.
  if (q.method === 'POST' && path === '/api/tv/prepare') { let b = ''; q.on('data', c => b += c); q.on('end', () => { let v = {}; try { v = JSON.parse(b || '{}'); } catch {} json({ ok: true, awake: true, fresh: !!v.token }); }); return true; }
  if (scene === 'cold' && path === '/api/tv/device') {
    return json({ model: 'onn. 4K Streaming Box', android: '14', resolution: '1920x1080', wifi: 'Home Wi-Fi', ip: '192.168.1.2', uptime: 122000, cpu: 0, memUsed: 1.4e9, memTotal: 2e9, diskUsed: 3.3e9, diskTotal: 4.7e9, tempC: 46, rxRate: 0, txRate: 0, hist: { cpu: [], mem: [], rx: [], tx: [] } });
  }
  if (path === '/api/tv/icon') {
    const blank = __dirname + '/tv-icons-blank/' + query.get('pkg') + '.png';
    const file = scene === 'blankbanner' && fs.existsSync(blank) ? blank : __dirname + '/tv-icons/' + query.get('pkg') + '.png';
    if (fs.existsSync(file)) { s.setHeader('content-type', 'image/png'); s.end(fs.readFileSync(file)); return true; }
    return false;
  }
  if (path === '/api/tv/discover' && !query.get('q') && !query.get('genre')) {
    tvPose.discover = tvPose.discover || JSON.parse(fs.readFileSync(__dirname + '/tv-discover.json'));
    return json(tvPose.discover[query.get('type') === 'series' ? 'series' : 'movie']);
  }
  // A still taken after a key press: the same picture here, at once.
  if (path === '/api/tv/shot' && q.url !== '/api/tv/shot') { s.setHeader('content-type', 'image/png'); s.end(homeStill); return true; }
  if (/^\/art[0-2]\.png$/.test(path)) {
    const tones = [[[200, 60, 40], [40, 20, 90]], [[30, 150, 110], [10, 40, 60]], [[230, 190, 60], [120, 30, 120]]][+path[4]];
    s.setHeader('content-type', 'image/png'); s.end(png(300, 300, tones[0], tones[1])); return true;
  }
  // No picture to be had: the stream answers and stays silent, and no still comes either.
  if (scene === 'rstall' && path === '/api/tv/screen-live') { s.writeHead(200, { 'content-type': 'video/h264', 'cache-control': 'no-store' }); s.flushHeaders(); return true; }
  if (scene === 'rstall' && path === '/api/tv/shot') { s.writeHead(503); s.end(); return true; }
  if (path === '/api/tv/screen-live') {
    // Cut into pictures at each slice that starts one, and sent a picture every 33 ms, over and over.
    if (!tvPose.units) {
      const d = fs.readFileSync(__dirname + '/tv-screen.h264'), cuts = [];
      for (let i = 0; i + 3 <= d.length; i++) if (d[i] === 0 && d[i + 1] === 0 && d[i + 2] === 1) cuts.push(i > 0 && d[i - 1] === 0 ? i - 1 : i);
      const units = []; let pending = [];
      cuts.forEach((at, k) => {
        const end = k + 1 < cuts.length ? cuts[k + 1] : d.length, nal = d.subarray(at, end), head = nal[nal[2] === 1 ? 3 : 4];
        const type = head & 31, first = (nal[(nal[2] === 1 ? 3 : 4) + 1] & 0x80) !== 0;
        if ((type === 1 || type === 5) && first && pending.some(n => { const t = n[n[2] === 1 ? 3 : 4] & 31; return t === 1 || t === 5; })) { units.push(Buffer.concat(pending)); pending = []; }
        pending.push(nal);
      });
      if (pending.length) units.push(Buffer.concat(pending));
      tvPose.units = units;
    }
    // Joining: the catch-up the bridge sends a viewer arriving mid-recording, all at once, then the live pictures.
    const replay = scene === 'rjoin' ? Math.min(60, tvPose.units.length) : 0;
    s.writeHead(200, { 'content-type': 'video/h264', 'cache-control': 'no-store', 'x-replay-frames': String(replay) });
    let n = 0, timer = null;
    const go = () => { timer = setInterval(() => { s.write(tvPose.units[n % tvPose.units.length]); n++; }, 33); };
    const wait = replay ? setTimeout(() => { s.write(Buffer.concat(tvPose.units.slice(0, replay))); n = replay; go(); }, 1200) : (go(), null);
    q.on('close', () => { clearTimeout(wait); clearInterval(timer); });
    return true;
  }
  if (/^r(tvoff|tvawayfilm|tvaway|cecoff|asleep|offline|youtube|youtubebare|mint|idle|episode|film|join|stall)$/.test(scene || '') && path === '/api/tv/status') {
    const v = JSON.parse(tvStatus), now = Date.now();
    // Which scene's status the app really asked for, so a shot showing the sample's song can be told apart from one that
    // never reached its scene (review of dfd490e: ryoutubebare showed Mint's Sample Song).
    try { fs.appendFileSync('/tmp/tv-scene-status.log', scene + '\n'); } catch {}
    if (scene === 'rasleep') { v.screen = 'asleep'; v.app = 'com.google.android.tvlauncher'; delete v.session; delete v.music; }
    if (scene === 'roffline') { v.online = false; delete v.session; }
    // The television behind the box, over HDMI-CEC: turned off with its own remote while the box is awake; on another
    // device that names itself; and CEC off on the box (only Status says so).
    if (scene === 'rtvoff') { v.app = 'com.google.android.tvlauncher'; delete v.session; delete v.music; v.cec = { enabled: true, tv: 'off', input: 'box', brand: 'Sony' }; }
    if (scene === 'rtvaway') { v.app = 'com.google.android.tvlauncher'; delete v.session; delete v.music; v.cec = { enabled: true, tv: 'on', input: 'other', source: 'PlayStation 5', brand: 'Sony', keys: true, others: ['PlayStation 5'] }; }
    // His real case: a film left paused for the PlayStation. The bar and keys stay under the dark picture; play brings the TV back.
    if (scene === 'rtvawayfilm') { v.app = 'com.stremio.one'; delete v.music; v.session = { pkg: 'com.stremio.one', playing: false, description: ['Heat'], position: 3000000, sampledAt: now, duration: 10200000, canSeek: true, art: tvBase + '/poster.png' }; v.cec = { enabled: true, tv: 'on', input: 'other', source: 'PlayStation 5', brand: 'Sony' }; }
    if (scene === 'rcecoff') { v.app = 'com.google.android.tvlauncher'; delete v.session; delete v.music; v.cec = { enabled: false }; }
    // A video the Mac hasn't found yet: no still, no length, only where it's got to (the yt-dlp search can take half a
    // minute or miss; r35: the Playing tab showed an empty box).
    if (scene === 'ryoutubebare') { v.app = 'com.google.android.youtube.tv'; delete v.music; v.session = { pkg: 'com.google.android.youtube.tv', playing: true, description: ['Lil B - Gotham City [ Music Video ] [ Official ]', 'Lil B'], position: 83000, sampledAt: now, canSeek: false }; }
    if (scene === 'ryoutube') { v.app = 'com.google.android.youtube.tv'; delete v.music; v.session = { pkg: 'com.google.android.youtube.tv', playing: true, description: ['Sample Video', 'Sample Channel'], position: 95000, sampledAt: now, duration: 610000, canSeek: false, art: tvBase + '/api/tv/shot' }; }
    if (scene === 'rmint') { v.app = 'com.codex.musicwebtv'; delete v.session; }
    if (scene === 'ridle') { v.app = 'com.google.android.tvlauncher'; delete v.session; delete v.music; }
    if (scene === 'rjoin' || scene === 'rstall') { v.app = 'com.google.android.tvlauncher'; delete v.session; delete v.music; }
    if (scene === 'rfilm') { v.app = 'com.stremio.one'; delete v.music; v.session = { pkg: 'com.stremio.one', playing: true, description: ['Heat'], position: 3000000, sampledAt: now, duration: 10200000, canSeek: true, art: tvBase + '/poster.png' }; }
    if (scene === 'repisode') { v.app = 'com.stremio.one'; delete v.music; v.session = { pkg: 'com.stremio.one', playing: true, description: ['Sample Series', 'S1E2 Episode Two'], position: 1260000, sampledAt: now, duration: 3480000, canSeek: true }; }
    return json(v);
  }
  // /live: the readings change under his finger, as the real box's do: every two seconds the last three apps come and go
  // (the Apps page's "Tools and settings" row with them) and the song pauses and plays (the Remote's player), so a fling
  // film on this scene shows whether a reading landing as a page is pulled past its end snaps it back (2026-11-08).
  if (scene === 'live' && path === '/api/tv/status') {
    const v = JSON.parse(tvStatus), odd = Math.floor(Date.now() / 2000) % 2 === 1;
    if (odd) v.apps = v.apps.slice(0, -3);
    v.music = { ...v.music, playing: !odd, sampledAt: Date.now() };
    return json(v);
  }
  if (scene === 'tour' && path === '/api/tv/status') {
    const v = JSON.parse(tvStatus);
    v.app = 'com.codex.musicwebtv';
    v.music = { ...v.music, art: tvBase + '/art' + (Math.floor(Date.now() / 5000) % 3) + '.png', sampledAt: Date.now() };
    return json(v);
  }
  if (scene === 'flickstream') {
    // How far into the start it is: nothing sent in the last 20 s is a fresh start.
    const t = tvPose.sent && Date.now() - tvPose.sent < 20000 ? (Date.now() - tvPose.sent) / 1000 : -1;
    if (path === '/api/tv/status') {
      const v = JSON.parse(tvStatus), now = Date.now();
      delete v.music;
      // Awake on the home screen first, as in every other shot of the sample TV, so nothing says it's waking.
      if (t < 2.4) v.app = 'com.google.android.tvlauncher';
      else v.app = 'com.stremio.one';
      if (t >= 3.6) v.session = { pkg: 'com.stremio.one', playing: t >= 5.2, description: ['Heat'], position: t >= 5.2 ? (t - 5.2) * 1000 : 0, sampledAt: now, duration: 10200000, canSeek: true };
      return json(v);
    }
    if (q.method === 'POST' && path === '/api/tv/play-stream') {
      tvPose.sent = Date.now();
      if (!/ndjson/.test(q.headers.accept || '')) { setTimeout(() => json({ ok: true }), 6000); return true; }
      s.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' });
      const lines = [[1200, { phase: 'awake' }], [2400, { phase: 'opening' }], [3600, { phase: 'player' }], [5200, { phase: 'playing' }], [6000, { ok: true }]];
      lines.forEach(([at, v]) => setTimeout(() => { s.write(JSON.stringify(v) + '\n'); if (v.ok) s.end(); }, at));
      return true;
    }
  }
  return false;
}

// The flick scenes. The film thrown is the first in Continue watching ("Heat", a made-up sample's title already used above).
function tvFlickStart(kind, q, s, path, json) {
  const fs = require('fs'), now = Date.now(), LOG = '/tmp/tv-flick-sends.log';
  if (path === '/reset') { tvFlickStart.st = null; tvFlickStart.alreadyAt = 0; try { fs.unlinkSync(LOG); } catch {} return json({ ok: true }); }
  const st = tvFlickStart.st && tvFlickStart.st.kind === kind ? tvFlickStart.st : (tvFlickStart.st = { kind, sent: 0, token: '', result: '', endedAt: 0, phase: '' });
  const log = (what, body) => fs.appendFileSync(LOG, JSON.stringify({ at: now, scene: kind, what, body }) + '\n');
  const read = f => { let b = ''; q.on('data', c => b += c); q.on('end', () => { let v = {}; try { v = JSON.parse(b || '{}'); } catch {} f(v); }); return true; };
  const film = { pkg: 'com.stremio.one', description: ['Heat'], sampledAt: now, duration: 10200000, canSeek: true, art: tvBase + '/poster.png' };
  if (path === '/api/tv/status') {
    const v = JSON.parse(tvStatus);
    delete v.music;
    // Already playing: the clock runs on from 30:00, as a real one does, rather than one spot repeated with a fresh time.
    if (kind === 'already') { tvFlickStart.alreadyAt = tvFlickStart.alreadyAt || now; v.app = 'com.stremio.one'; v.session = { ...film, playing: true, position: 1800000 + (now - tvFlickStart.alreadyAt) }; return json(v); }
    const t = st.sent ? now - st.sent : -1;
    const playAt = kind === 'slow' ? 9000 : 3200;
    if (t < 0 || (st.result && st.result !== 'ok')) v.app = 'com.google.android.tvlauncher';
    else if (st.result === 'ok' || t >= playAt) { v.app = 'com.stremio.one'; v.session = { ...film, playing: true, position: Math.round((st.resume || 0) * film.duration) + Math.max(0, t - playAt) }; }
    else { v.app = t >= 2000 ? 'com.stremio.one' : 'com.google.android.tvlauncher'; v.starting = { imdb: 'tt7654320', token: st.token, phase: st.phase || 'awake', since: st.sent }; }
    if (st.result && now - st.endedAt < 30000) v.lastStart = { result: st.result, token: st.token, at: st.endedAt };
    return json(v);
  }
  if (q.method === 'POST' && path === '/api/tv/prepare') return read(b => { log('prepare', b); setTimeout(() => json({ ok: true, awake: true, fresh: !!b.token }), 300); });
  if (q.method === 'POST' && path === '/api/tv/key') return read(b => { log('key', b); json({ ok: true }); });
  // The app's hand-off timing (frame hitches from release to landing), so the build's log has a line to read.
  if (q.method === 'POST' && path === '/api/tv/timing') return read(b => { log('timing', b); json({ ok: true }); });
  if (q.method === 'POST' && /^\/api\/tv\/(flick|open|stremio-open|film|send|mint-open|music|stop-playing)$/.test(path)) return read(b => { log(path.slice(8), b); if (path.endsWith('stop-playing')) { st.result = 'stopped'; st.endedAt = Date.now(); } json({ ok: true }); });
  if (q.method === 'POST' && path === '/api/tv/play-stream') return read(b => {
    log('play-stream', b);
    const begun = Date.now(), tokens = [b.token, ...(Array.isArray(b.fallbacks) ? b.fallbacks : [])].filter(x => typeof x === 'string').slice(0, 3);
    Object.assign(st, { sent: begun, token: tokens[0] || '', result: '', endedAt: 0, phase: 'awake', resume: typeof b.resume === 'number' ? b.resume : 0 });
    const steps = [];
    if (kind === 'fail') {
      // Each stream tried in turn, the next one after a failed start, then given up.
      tokens.forEach((tok, n) => {
        const base = n * 2000;
        if (n) steps.push([base, { phase: 'retry', n }]);
        if (!n) steps.push([0, { phase: 'awake' }]);
        steps.push([base + 120, { phase: 'sent' }]);
      });
      steps.push([tokens.length * 2000, { error: 'That stream didn’t start on the TV', failed: 'start', token: tokens[tokens.length - 1] || '' }]);
    } else if (kind === 'bridgeon') {
      // The bridge found it already on the TV (the phone hadn't known): every step at once and a plain yes, nothing sent.
      steps.push([0, { phase: 'awake' }], [60, { phase: 'player' }], [120, { phase: 'playing' }], [180, { ok: true, alreadyOn: true, token: tokens[0] || '' }]);
    } else {
      const playAt = kind === 'slow' ? 9000 : 3200;
      // Joined: a second identical send rides along with the start already under way, and hears the same yes.
      steps.push([0, { phase: 'awake' }], [120, { phase: 'sent' }], [2000, { phase: 'player' }], [playAt, { phase: 'playing' }], [playAt + 200, { ok: true, token: tokens[0] || '', ...(kind === 'joined' ? { joined: true } : {}) }]);
    }
    // Not answering: not a byte for 2 s, then the start as usual.
    const delay = kind === 'offline' ? 2000 : 0;
    const finish = v => { if (v.ok) { st.result = 'ok'; } else if (v.error) { st.result = v.error; } if (v.ok || v.error) st.endedAt = Date.now(); if (v.phase) st.phase = v.phase; if (v.phase === 'retry') st.token = tokens[v.n] || st.token; };
    if (!/ndjson/.test(q.headers.accept || '')) {
      const last = steps[steps.length - 1];
      return setTimeout(() => { steps.forEach(([, v]) => finish(v)); json(last[1]); }, delay + last[0]);
    }
    setTimeout(() => {
      s.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' });
      steps.forEach(([at, v]) => setTimeout(() => {
        finish(v);
        s.write(JSON.stringify({ ...v, at: Date.now() - begun }) + '\n');
        if (v.ok || v.error) s.end();
      }, at));
    }, delay);
  });
  return false;
}

// The /real scene. Made-up titles and pictures only: the repo is public, so nothing from his own watching.
function tvReal(q, s, path, query, json) {
  const fs = require('fs'), now = Date.now();
  // CI starts each flow from the top: the episode at 0:00, no length yet, and an empty send log.
  if (path === '/reset') { tvReal.state = null; tvReal.hold = false; try { fs.unlinkSync('/tmp/tv-real-sends.log'); } catch {} return json({ ok: true }); }
  // The TV, once gone at 30 s, stays gone until /release, so the build's shot of it gone never misses (r33, r34: the phone
  // showed it gone at 37-43 s one run and 42-46 s the next, and both shots landed outside).
  if (path === '/hold-offline') { tvReal.hold = true; return json({ ok: true }); }
  if (path === '/release') { tvReal.hold = false; if (tvReal.state) tvReal.state.back = Date.now(); return json({ ok: true }); }
  // A fresh launch (nothing asked for 15 s) starts the episode again from 0:00.
  const r = tvReal.state && now - tvReal.state.last < 15000 ? tvReal.state
    : (tvReal.state = { start: now, asks: 0, playing: true, pos: 0, posAt: now, seeked: false, flips: [] });
  r.last = now;
  const t = (now - r.start) / 1000;
  const REAL_MS = 1315000, CATALOGUE_MS = 1560000;
  const here = () => r.playing ? r.pos + (now - r.posAt) : r.pos;
  // Each key reaches the status a little after it was pressed, as on the box.
  r.flips = r.flips.filter(f => { if (now < f.at) return true; r.pos = here(); r.posAt = now; r.playing = f.playing; return false; });
  const log = (what, body) => fs.appendFileSync('/tmp/tv-real-sends.log', JSON.stringify({ t: Math.round(t * 10) / 10, what, body }) + '\n');
  const late = (ms, f) => { setTimeout(f, ms); return true; };
  const read = f => { let b = ''; q.on('data', c => b += c); q.on('end', () => { let v = {}; try { v = JSON.parse(b || '{}'); } catch {} f(v); }); return true; };
  const show = { title: 'Sample Show', subtitle: 'S2 E3', art: tvBase + '/poster.png', id: 'tt1234567', kind: 'series', progress: 0.1, about: 'A made-up comedy about a made-up family.' };
  const home = { rows: [
    { title: 'Continue watching', items: [show, { title: 'A Long Film', subtitle: '88 min left', art: tvBase + '/poster.png', id: 'tt7654321', kind: 'movie', progress: 0.3, about: 'A made-up film.' }] },
    { title: 'Popular movies', items: ['Heat', 'Night Harbour'].map((title, n) => ({ title, subtitle: '1995 · ★ 8.3', art: tvBase + '/poster.png', id: 'tt76543' + n, kind: 'movie', about: 'A made-up film.' })) },
    { title: 'Popular series', items: ['Sample Show', 'Quiet Valley', 'Paper Town'].map((title, n) => ({ title, subtitle: '2004 · ★ 8.7', art: tvBase + '/poster.png', id: n ? 'tt12345' + n : 'tt1234567', kind: 'series', about: 'A made-up series.' })) },
    { title: 'New and notable', items: [{ title: 'Late Train', subtitle: '2025', art: tvBase + '/poster.png', id: 'tt7654399', kind: 'movie', about: 'A made-up film.' }] },
  ] };
  if (path === '/api/tv/status') {
    r.asks++;
    const v = JSON.parse(tvStatus);
    if (t >= 30 && (t < 35 || tvReal.hold) && !r.back) { v.online = false; delete v.music; return late(400, () => json(v)); }
    v.app = 'com.stremio.one';
    // Mint's session stays listed, paused, after a film has started over it.
    v.music = { title: 'A Paused Song', artist: 'Some Band', album: 'Some Album', art: tvBase + '/art.png', playing: false, position: 61000, duration: 214000, sampledAt: now - 600000 };
    const session = { pkg: 'com.stremio.one', playing: r.playing, description: ['Sample Show - S02E03 - The Third One'], position: Math.max(0, Math.round(here())), sampledAt: now, canSeek: true, art: tvBase + '/poster.png', show: 'Sample Show', season: 2, episode: 3, episodeTitle: 'The Third One' };
    if (r.seeked || tvReal.known) session.duration = REAL_MS; else if (t >= 20) session.duration = CATALOGUE_MS;
    v.session = session;
    return late(r.asks % 7 === 0 ? 2000 : 300 + Math.round(Math.random() * 600), () => json(v));
  }
  // The series lookup takes a few seconds, as the real catalogue can, so ⏭ pressed before it's in shows its light (r21).
  if (path === '/api/tv/stremio-meta') {
    const eps = [1, 2, 3, 4].flatMap(n => [1, 2].map(season => ({ id: 'tt1234567:' + season + ':' + n, season, episode: n, name: n % 2 ? 'Episode ' + n : 'Episode ' + n + ': The One Where Everybody Finally Comes Home for the Long Weekend', thumb: tvBase + '/still.png', runtime: 21 + (n % 3), overview: 'A made-up afternoon goes sideways when the family visits.' })));
    return late(3000, () => json({ about: 'A made-up comedy about a made-up family.', episodes: eps }));
  }
  if (path === '/api/tv/stremio' || (path === '/api/tv/discover' && !query.get('genre'))) {
    const term = (query.get('q') || '').toLowerCase();
    if (!term) return late(700, () => json(home));
    const all = home.rows.flatMap(x => x.items), seen = new Set();
    // The catalogue's own search (discover) answers one kind, and quickly; Stremio's answers both, slowly.
    const kind = path === '/api/tv/discover' ? (query.get('type') === 'series' ? 'series' : 'movie') : null;
    const hits = all.filter(i => i.title.toLowerCase().includes(term) && (!kind || (i.kind === 'series') === (kind === 'series')) && !seen.has(i.id) && seen.add(i.id));
    return late(kind ? 150 : 900, () => json({ rows: hits.length ? [{ title: 'Results', items: hits }] : [] }));
  }
  if (q.method === 'POST' && path === '/api/tv/timing') return read(b => { log('timing', b); json({ ok: true }); });
  if (q.method === 'POST' && path === '/api/tv/key') return read(b => {
    log('key', b);
    const k = String(b.key || '');
    // "play" is the box's play/pause key: it turns whatever is on.
    // "resume" is MEDIA_PLAY: it only ever plays.
    if (/^(play|pause|playpause|play_pause|media_play_pause|resume)$/.test(k)) r.flips.push({ at: Date.now() + 2200, playing: k === 'pause' ? false : k === 'resume' ? true : !(r.flips.length ? r.flips[r.flips.length - 1].playing : r.playing) });
    json({ ok: true, r: 'sent' });
  });
  if (q.method === 'POST' && /^\/api\/tv\/player-seek(-to)?$/.test(path)) return read(b => {
    log(path.slice(8), b);
    late(1500, () => {
      r.pos = path.endsWith('-to') ? Math.max(0, +b.ms || 0) : Math.max(0, here() + (+b.steps || 0) * 10000); r.posAt = Date.now(); r.seeked = true;
      if (path.endsWith('-to') && b.play) r.playing = true;
      json({ ok: true, position: r.pos, duration: REAL_MS });
    });
  });
  if (q.method === 'POST' && /^\/api\/tv\/(play-stream|flick|open|prepare|stremio-open|film|send|mint-open|music|stop-playing)$/.test(path)) return read(b => {
    log(path.slice(8), b);
    if (path === '/api/tv/prepare') return late(1200, () => json({ ok: true, awake: true, fresh: !!b.token }));
    if (path !== '/api/tv/play-stream') return late(800, () => json({ ok: true }));
    // As the real box: the episode playing is stopped and the stream starts over from 0:00 about 12 s later.
    const steps = [[800, { phase: 'awake' }], [1400, { phase: 'opening' }], [7100, { phase: 'player' }], [12000, { phase: 'playing' }], [12400, { ok: true }]];
    r.playing = false; r.pos = 0; r.posAt = Date.now(); r.seeked = false;
    setTimeout(() => { r.playing = true; r.pos = 0; r.posAt = Date.now(); }, 12000);
    if (!/ndjson/.test(q.headers.accept || '')) return late(12400, () => json({ ok: true }));
    s.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' });
    steps.forEach(([at, v]) => setTimeout(() => { s.write(JSON.stringify(v) + '\n'); if (v.ok) s.end(); }, at));
  });
  return false;
}

// A stand-in for the Mac's Screen Sharing behind the dashboard's bridge, for the Mac Pro app's measuring shots of the
// remote screen: the bridge's handshake, then a page of lyrics that scrolls a little every 16 ms, sent as raw pixels.
// Every answer is held back 45 ms, about a trip over Tailscale, so asking for one picture at a time shows what it costs.
// It logs how many pictures a second it sends.
// A stand-in for the Mac's Screen Sharing. The app's pixel format is honoured (32-bit BGRX or 16-bit 5-6-5). With
// `slow`, it behaves as the real Mac does over his link (2026-11-07): the whole screen as one ZRLE rectangle, a busy
// wallpaper so it's about as big as the Mac's, and everything sent at 358 KB/s, the speed his sessions showed.
function mockScreen(req, sock, slow = false) {
  const key = req.headers['sec-websocket-key'];
  if (!key || !req.url.startsWith('/novnc/ws/vnc')) return sock.destroy();
  const accept = require('crypto').createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\nSec-WebSocket-Protocol: binary\r\n\r\n`);
  sock.setNoDelay(true);
  const W = 1280, H = 800, LAG = 45;
  const frame = data => {
    const n = data.length;
    const head = n < 126 ? Buffer.from([0x82, n]) : n < 65536 ? Buffer.from([0x82, 126, n >> 8, n & 255])
      : Buffer.concat([Buffer.from([0x82, 127, 0, 0, 0, 0]), (b => (b.writeUInt32BE(n), b))(Buffer.alloc(4))]);
    if (!sock.destroyed) { sock.write(head); sock.write(data); }
  };
  // Slow: bytes leave at 358 KB/s, in 20 ms slices, as a link that speed would deliver them.
  const RATE = 358000, outbox = [];
  const pump = slow ? setInterval(() => {
    let budget = RATE / 50;
    while (budget > 0 && outbox.length) {
      const b = outbox[0];
      if (b.length <= budget) { outbox.shift(); budget -= b.length; frame(b); }
      else { frame(b.subarray(0, budget)); outbox[0] = b.subarray(budget); budget = 0; }
    }
  }, 20) : null;
  const later = data => setTimeout(() => (slow ? outbox.push(data) : frame(data)), LAG);
  // Colours as 0xRRGGBB, put in the app's pixel format when sent.
  let bpp = 32;
  const bg = 0x1c162c, bright = 0xebebf5, dim = 0x786e96, side = 0x121216;
  const band = { x: 240, y: 120, w: 800, h: 560 };
  // The wallpaper of the slow stand-in: noise in 2 × 2 blocks over a gradient, which deflates about as well as a
  // real desktop does.
  const wall = (X, Y) => {
    let n = (X * 73856093) ^ (Y * 19349663); n = Math.imul(n ^ (n >>> 13), 1274126177); n ^= n >>> 16;
    const t = Y / H;
    const r = 205 + (t * 30 | 0) + (n & 15), g = 120 + (t * 40 | 0) + ((n >> 4) & 31), b = 175 + ((n >> 9) & 31);
    return (Math.min(r, 255) << 16) | (Math.min(g, 255) << 8) | Math.min(b, 255);
  };
  const paint = (x0, y0, w, h, scroll) => {
    const out = new Uint32Array(w * h);
    for (let y = 0; y < h; y++) {
      const Y = y0 + y, row = y * w;
      if (Y < band.y || Y >= band.y + band.h) {
        if (slow) for (let x = 0; x < w; x++) out[row + x] = wall(x0 + x, Y); else out.fill(side, row, row + w);
        continue;
      }
      out.fill(bg, row, row + w);
      if (slow) for (let x = 0; x < w; x++) { const X = x0 + x; if (X < band.x || X >= band.x + band.w) out[row + x] = wall(X, Y); }
      // A line every 56 px, 22 px tall and of varying length; the one in the middle bright, the rest dim.
      const v = Y - band.y + scroll, k = Math.floor(v / 56);
      if (v % 56 >= 22) continue;
      const len = 260 + ((k * 137) % 420), mid = Math.abs(Y - (band.y + band.h / 2)) < 30;
      const from = Math.max(x0, band.x + 40), to = Math.min(x0 + w, band.x + 40 + len);
      if (to > from) out.fill(mid ? bright : dim, row + (from - x0), row + (to - x0));
    }
    return out;
  };
  const wide = c => ((((c >> 19) & 31) << 11) | (((c >> 10) & 63) << 5) | ((c >> 3) & 31));
  // Raw pixels: 4 bytes BGRX, or 2 bytes 5-6-5, little-endian.
  const raw = px => {
    const out = Buffer.alloc(px.length * (bpp / 8));
    if (bpp === 32) px.forEach((c, i) => out.writeUInt32LE(c, i * 4)); else px.forEach((c, i) => out.writeUInt16LE(wide(c), i * 2));
    return out;
  };
  // ZRLE: 64-pixel tiles, solid where they're one colour, raw otherwise, in compact pixels (3 bytes, or 2), through one
  // deflate stream for the whole connection.
  const deflate = zlib.createDeflate();
  let zchain = Promise.resolve();
  const zrle = (px, w, h) => {
    // Written straight into one buffer: a Buffer per pixel took the CI runner seconds per picture.
    const size = bpp === 32 ? 3 : 2, out = Buffer.alloc(Math.ceil(w / 64) * Math.ceil(h / 64) + w * h * size);
    let at = 0;
    const put = c => {
      if (size === 3) { out[at++] = c & 255; out[at++] = (c >> 8) & 255; out[at++] = (c >> 16) & 255; }
      else { const v = wide(c); out[at++] = v & 255; out[at++] = v >> 8; }
    };
    for (let ty = 0; ty < h; ty += 64) for (let tx = 0; tx < w; tx += 64) {
      const tw = Math.min(64, w - tx), th = Math.min(64, h - ty), first = px[ty * w + tx];
      let solid = true;
      for (let y = 0; y < th && solid; y++) for (let x = 0; x < tw; x++) if (px[(ty + y) * w + tx + x] !== first) { solid = false; break; }
      if (solid) { out[at++] = 1; put(first); continue; }
      out[at++] = 0;
      for (let y = 0; y < th; y++) for (let x = 0; x < tw; x++) put(px[(ty + y) * w + tx + x]);
    }
    const input = out.subarray(0, at);
    return new Promise(res => {
      const got = []; const take = d => got.push(d);
      deflate.on('data', take);
      deflate.write(input);
      deflate.flush(zlib.constants.Z_SYNC_FLUSH, () => { deflate.off('data', take); res(Buffer.concat(got)); });
    });
  };
  const update = (x, y, w, h, scroll) => {
    const head = Buffer.alloc(16);
    head.writeUInt16BE(1, 2);
    head.writeUInt16BE(x, 4); head.writeUInt16BE(y, 6); head.writeUInt16BE(w, 8); head.writeUInt16BE(h, 10);
    const px = paint(x, y, w, h, scroll);
    if (!slow) { head.writeInt32BE(0, 12); later(Buffer.concat([head, raw(px)])); return; }
    head.writeInt32BE(16, 12);
    zchain = zchain.then(() => zrle(px, w, h)).then(z => {
      const len = Buffer.alloc(4); len.writeUInt32BE(z.length);
      later(Buffer.concat([head, len, z]));
    });
  };
  let stage = 0, pending = 0, scroll = 0, sent = -1, count = 0, buf = Buffer.alloc(0), msgs = Buffer.alloc(0);
  // Like a real server: an answer goes out when there's a request waiting and the page has moved since the last one.
  // Slow, the page holds still: a moving page there would only queue behind the first picture, as on the real link.
  const answer = () => { if (pending > 0 && sent !== scroll) { pending--; sent = scroll; count++; update(band.x, band.y, band.w, band.h, scroll); } };
  const tick = setInterval(() => { if (!slow) scroll += 3; answer(); }, 16);
  const report = setInterval(() => { if (count) console.log(`mock screen: ${Math.round(count / 2)} pictures a second`); count = 0; }, 2000);
  const stop = () => { clearInterval(tick); clearInterval(report); if (pump) clearInterval(pump); sock.destroy(); };
  sock.on('close', stop); sock.on('error', stop);
  later(Buffer.from('RFB 003.008\n'));
  const fromApp = d => {
    msgs = Buffer.concat([msgs, d]);
    for (;;) {
      if (stage === 0) { if (msgs.length < 12) return; msgs = msgs.subarray(12); stage = 1; later(Buffer.from([1, 1])); continue; }
      if (stage === 1) { if (msgs.length < 1) return; msgs = msgs.subarray(1); stage = 2; later(Buffer.alloc(4)); continue; }
      if (stage === 2) {
        if (msgs.length < 1) return;
        msgs = msgs.subarray(1); stage = 3;
        const init = Buffer.alloc(28);
        init.writeUInt16BE(W, 0); init.writeUInt16BE(H, 2);
        Buffer.from([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]).copy(init, 4);
        init.writeUInt32BE(4, 20); init.write('Mock', 24);
        later(init);
        continue;
      }
      if (!msgs.length) return;
      const t = msgs[0];
      const need = t === 0 ? 20 : t === 2 ? (msgs.length >= 4 ? 4 + 4 * msgs.readUInt16BE(2) : 4) : t === 3 ? 10 : t === 4 ? 8 : t === 5 ? 6
        : t === 6 ? (msgs.length >= 8 ? 8 + msgs.readUInt32BE(4) : 8) : 1;
      if (msgs.length < need) return;
      const m = msgs.subarray(0, need); msgs = msgs.subarray(need);
      if (t === 0) bpp = m[4] === 16 ? 16 : 32;
      if (t === 3) {
        if (m[1] === 0) { count++; sent = scroll; update(0, 0, W, H, scroll); }
        else { pending++; answer(); }
      }
    }
  };
  sock.on('data', d => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
      if (buf.length < 2) return;
      let n = buf[1] & 127, at = 2;
      if (n === 126) { if (buf.length < 4) return; n = buf.readUInt16BE(2); at = 4; }
      else if (n === 127) { if (buf.length < 10) return; n = Number(buf.readBigUInt64BE(2)); at = 10; }
      if (buf.length < at + 4 + n) return;
      const op = buf[0] & 15, mask = buf.subarray(at, at + 4), data = Buffer.from(buf.subarray(at + 4, at + 4 + n));
      for (let i = 0; i < n; i++) data[i] ^= mask[i & 3];
      buf = buf.subarray(at + 4 + n);
      if (op === 8) return stop();
      if (op === 2 || op === 0) fromApp(data);
    }
  });
}
