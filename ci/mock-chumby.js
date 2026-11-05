// Sample Chumby answers so the cloud build can screenshot every tab without a real device.
const http = require('http');
const alarm = (o) => ({ name: '', enabled: '1', time: '420', when: 'weekday', type: 'beep', arg: 'Beep', param: '', param_description: 'Beep', duration: '30', snooze: '9', auto_dismiss: '0', action: '', action_param: '', backup: '1', backupDelay: '5', ...o });
const data = {
  tok: { t: 'test' },
  sys: { ok: true, up: 291000, memFree: 22000, memTotal: 62000, pspFree: 3100, load: 0.42, wifi: 71, vol: 40, shuffle: 0, airplayOn: true, chan: 'Default', cp: '1.7.3', lock: '', wall: 1, tw: ['NASA', 'BBCBreaking'] },
  state: {
    ok: true, volume: 80, fade: 30, pending: false, shuffle: 0, channel: 'Default', skipped: null,
    alarms: [alarm({ name: 'Work', time: '405' }), alarm({ name: 'Weekend', time: '570', when: 'weekend', enabled: '0', type: 'audio', arg: 'directurl', param_description: 'Jazz Radio' })],
    streams: [{ id: 's1', name: 'Jazz Radio', url: 'http://example.com/jazz.mp3', mimetype: 'audio/mpeg' }],
    tones: ['Beep', 'Bells', 'Chime'], channels: [{ id: 'A', name: 'Default' }, { id: 'B', name: 'News' }],
    pandora: [{ id: '1', name: 'Morning Mix' }], pandoraScan: '',
    schedule: [{ time: '22:30', cmd: 'night', val: 'on' }, { time: '07:00', cmd: 'night', val: 'off' }],
    channelNames: ['Default', 'News'], widgetNames: ['Clock', 'Weather', 'X'], mine: [{ name: 'X', secs: 60 }, { name: 'NYT', secs: 45 }],
  },
  chlist: { cur: 'A', names: [['W3', 'Moon Phase']], channels: [{ id: 'A', conf: [['W1', '1', '30'], ['W2', '0', '0']], list: [['#', 'Default'], ['W1', 'Clock', '30'], ['W2', 'Weather', '15']] }, { id: 'B', conf: [], list: [['#', 'News'], ['W4', 'NYT', '45']] }] },
};
http.createServer((q, s) => {
  if (chumbyScene(q, s)) return;   // the Chumby app's poses; see the block at the end
  const a = new URL(q.url, 'http://x').searchParams.get('a');
  if (a === 'shot') { s.setHeader('content-type', 'image/jpeg'); s.end(require('fs').readFileSync(__dirname + '/shot.jpg')); return; }
  if (a === 'cat') { s.end('<a href="/guide/AB-1/category"><img alt="Clocks"></a>'); return; }
  if (q.method === 'POST') { s.end('{"ok":true}'); return; }
  if (data[a]) { s.setHeader('content-type', 'application/json'); s.end(JSON.stringify(data[a])); return; }
  s.statusCode = 404; s.end();
}).listen(9000, '127.0.0.1');
// And a sample Mac for the Mac Pro app.
const macMock = JSON.parse(require('fs').readFileSync(__dirname + '/mock-status.json'));
{ // Times relative to now, so the screenshots show what a real day looks like.
  const now = Date.now(), plan = macMock.usage.plan;
  plan.at = now - 120000; plan.fiveHourResets = now + 3 * 3600e3; plan.sevenDayResets = now + 4 * 86400e3;
  macMock.iosApps.apps.forEach(a => { if (a.expires) { a.expires = now + 6 * 86400e3; a.installedAt = now - 86400e3; } });
  macMock.usage.hours.forEach((h, i, all) => { h.t = now - (all.length - 1 - i) * 3600e3; });
  macMock.claude.sessions = [
    { name: 'Tahoe upgrade', status: 'busy', cwd: '~/code', remote: true, updated: now - 240000, key: null, restartable: false, stuck: false },
    { name: 'TV plugin', status: 'busy', cwd: '~/code', remote: true, updated: now - 7200000, key: 'tv', restartable: true, stuck: true },
    { name: 'Chumby widget', status: 'idle', cwd: '~/code', remote: true, updated: now - 3600000, key: 'chumby', restartable: true, stuck: false },
    { name: 'build', status: 'stopped', cwd: '~/code', remote: false, updated: null, key: 'build', restartable: true, stuck: false },
  ];
}
const macStatus = JSON.stringify(macMock);
const macProc = (pid, name, cpu, mem, locked) => ({ pid, start: 'Fri Oct 30 23:11:35 2026', name, cpu, mem: mem * 1048576, locked });
const macProcs = JSON.stringify({
  cpu: [macProc(40, 'Google Chrome Helper', 84, 610, null), macProc(41, 'WindowServer', 22, 240, 'System process'), macProc(42, 'Claude Code', 12, 690, 'Claude session'), macProc(43, 'Music', 6, 380, null), macProc(44, 'node', 3, 310, 'The dashboard'), macProc(45, 'Tailscale', 2, 118, 'Keeps remote access')],
  mem: [macProc(42, 'Claude Code', 12, 690, 'Claude session'), macProc(40, 'Google Chrome Helper', 84, 610, null), macProc(46, 'mediaanalysisd', 0, 490, 'System process'), macProc(43, 'Music', 6, 380, null), macProc(44, 'node', 3, 310, 'The dashboard'), macProc(47, 'Code Helper', 1, 290, null)],
});
http.createServer((q, s) => { s.setHeader('content-type', 'application/json'); if (q.url.startsWith('/api/trend')) { const now = Date.now(); return s.end(JSON.stringify({ points: Array.from({ length: 1440 }, (_, i) => { const v = 14 + 9 * Math.sin(i / 90) + 5 * Math.sin(i / 7) + (i % 211 < 12 ? 38 : 0); return { t: now - (1440 - i) * 60000, v: Math.max(1, v), peak: Math.min(100, v + 12) }; }).filter((_, i) => i < 600 || i > 660) })); } if (q.url.startsWith('/api/term')) return s.end(JSON.stringify({ running: true, text: '╭─ Claude Code ─╮\n\n> fix the widget\n\n⏺ Updated widget.swift\n\n  Teach auto mode about your environment?\n  ❯ 1. Yes\n    2. Not now\n    3. Don\'t show again\n\n  Enter to confirm · Esc to cancel' })); s.end(q.url === '/api/status' ? macStatus : q.url === '/api/procs' ? macProcs : '{}'); }).listen(9001, '127.0.0.1').on('upgrade', mockScreen);
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
const tvStremio = JSON.stringify({ rows: ['Continue watching', 'Popular movies', 'Popular series'].map(title => ({ title, items: ['Heat', 'Alien', 'Chinatown', 'Thief'].map((t, n) => ({ title: t, subtitle: title === 'Continue watching' ? `Continue · ${85 - 11 * n}m left` : '1995 · ★ 8.3', art: tvBase + '/poster.png', id: (title === 'Popular series' ? 'tt123456' : 'tt765432') + n, kind: title === 'Popular series' ? 'series' : 'movie', progress: t === 'Alien' ? 0.4 : undefined, about: 'A sample description of the film.' })) })) });
// A TV with a player open, for the shots of what the app shows then. Asked for by putting /stremio or /youtube in front
// of the address, so every other shot gets the same answers as before.
const tvScene = scene => {
  const v = JSON.parse(tvStatus), now = Date.now();
  if (scene === 'stremio') { v.app = 'com.stremio.one'; v.session = { pkg: 'com.stremio.one', playing: true, description: ['Sample Series', 'S1E2 Episode 2'], position: 1260000, sampledAt: now, duration: 3480000, canSeek: true, art: tvBase + '/poster.png' }; }
  // A film nearly over, for Start over and for skips still on their way.
  if (scene === 'ending') { v.app = 'com.stremio.one'; v.session = { pkg: 'com.stremio.one', playing: true, description: ['Heat'], position: 7600000, sampledAt: now, duration: 8000000, canSeek: true, art: tvBase + '/poster.png' }; }
  if (scene === 'youtube') { v.app = 'com.google.android.youtube.tv'; v.session = { pkg: 'com.google.android.youtube.tv', playing: true, description: ['A sample video', 'Sample Channel'], position: 95000, sampledAt: now, duration: 600000, canSeek: false }; }
  return JSON.stringify(v);
};
http.createServer((q, s) => {
  if (tvPose(q, s)) return;
  const scene = (q.url.match(/^\/(stremio|youtube|ending)(?=\/)/) || [])[1];
  if (scene) q.url = q.url.slice(scene.length + 1);
  if (scene && q.url === '/api/tv/status') { s.setHeader('content-type', 'application/json'); return s.end(tvScene(scene)); }
  // Skips take the real player a few seconds, so the shot catches them still on their way.
  if (scene && q.method === 'POST' && q.url === '/api/tv/player-seek') { s.setHeader('content-type', 'application/json'); return setTimeout(() => s.end(JSON.stringify({ ok: true, position: 7630000, duration: 8000000 })), 6000); }
  if (q.url.startsWith('/api/tv/mint')) { s.setHeader('content-type', 'application/json'); return s.end(tvMint); }
  if (q.url.startsWith('/api/tv/streams')) { s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify({ streams: [['1080p', '1080p', 3.2, ''], ['1080p', '1080p', 1.4, ''], ['4K HDR', '4K', 18.4, 'HDR'], ['720p', '720p', 0.9, '']].map(([name, quality, gb, hdr], n) => ({ token: 's' + n, addon: 'Sample addon', name, description: 'Sample.Film.2024.' + quality + '.WEB-DL.x264', quality, hdr, gb, instant: n < 3 })) })); }
  if (q.url.startsWith('/api/tv/discover')) { s.setHeader('content-type', 'application/json'); return s.end(tvStremio); }
  if (q.url.startsWith('/api/tv/stremio-meta')) { s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify({ about: 'A sample series, for the screenshot.', episodes: [1, 2, 3, 4].flatMap(n => [1, 2].map(season => ({ id: 'tt1234567:' + season + ':' + n, season, episode: n, name: 'Episode ' + n, thumb: tvBase + '/poster.png' }))) })); }
  if (q.url.startsWith('/api/tv/recs')) { s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify({ films: ['Rope', 'Match Point', 'Blue Velvet', 'Klute'].map(title => ({ title, year: '1990', slug: title.toLowerCase(), imdb: 'tt1234567', art: tvBase + '/poster.png', why: 'Because you liked Heat' })) })); }
  if (q.url.startsWith('/api/tv/stremio')) { s.setHeader('content-type', 'application/json'); return s.end(tvStremio); }
  if (q.url === '/api/tv/device-image') { s.setHeader('content-type', 'image/png'); return s.end(pictures.square); }
  if (q.url === '/api/tv/device') { const up = [12, 18, 9, 22, 30, 14, 11, 16, 25, 19]; s.setHeader('content-type', 'application/json'); return s.end(JSON.stringify({ model: 'onn. 4K Streaming Box', android: '14', resolution: '1920x1080', wifi: 'Home Wi-Fi', ip: '192.168.1.2', uptime: 122000, cpu: 18, memUsed: 1.4e9, memTotal: 2e9, diskUsed: 3.3e9, diskTotal: 4.7e9, tempC: 46, rxRate: 2.4e6, txRate: 8e4, hist: { cpu: up, mem: up.map(x => x + 50), rx: up, tx: up } })); }
  if (q.url === '/api/tv/shot') { s.setHeader('content-type', 'image/jpeg'); return s.end(require('fs').readFileSync(__dirname + '/shot.jpg')); }
  if (q.url.startsWith('/api/tv/icon')) { s.setHeader('content-type', 'image/png'); const a = tvApps.find(x => q.url.endsWith(x[0])); return s.end(a && a[2] ? pictures.wide : pictures.square); }
  // Sending to the TV takes a moment there, so the waiting can be seen.
  if (q.method === 'POST' && /play-stream|stremio-open|mint-open/.test(q.url)) { s.setHeader('content-type', 'application/json'); return setTimeout(() => s.end('{"ok":true}'), 3000); }
  if (q.url === '/poster.png' || q.url === '/art.png') { s.setHeader('content-type', 'image/png'); return s.end(pictures[q.url.slice(1, -4)]); }
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
    songs.push({ t: t + 70, title: 'So What', artist: 'Miles Davis', album: 'Kind of Blue' }, { t: t + 640, title: 'Take Five', artist: 'The Dave Brubeck Quartet', album: 'Time Out' });
  }
  data.hist = { ok: true, songs: songs.sort((x, y) => y.t - x.t) };
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
function chumbyScene(q, s) {
  const a = new URL(q.url, 'http://x').searchParams.get('a');
  // A real 320 x 240 capture from the Chumby on every Chumby shot, so the hero can be judged.
  const shot = () => { s.setHeader('content-type', 'image/jpeg'); s.end(require('fs').readFileSync(__dirname + '/chumby-screen.jpg')); return true; };
  if (a === 'shot' && !/^\/slow\//.test(q.url)) return shot();
  const m = q.url.match(/^\/(ringing|snoozed|dead|slow|fail|live|liveringing|skipped)\//);
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
        // The panel's own skip, as the Chumby answers it.
        if (a === 'skip') { live.state.skipped = nextWork(); return json({ ok: true, pending: false, skipped: live.state.skipped }); }
        if (a === 'unskip') { live.state.skipped = null; return json({ ok: true, pending: false, skipped: null }); }
        // A channel chosen in the app stays chosen, so Now playing doesn't snap back on the next reading.
        if (a === 'cmd' && qs.get('c') === 'channel') { live.state.channel = qs.get('v'); live.sys.chan = qs.get('v'); }
        if (a === 'save') {
          const keys = ['name', 'enabled', 'time', 'when', 'type', 'arg', 'param', 'param_description', 'duration', 'snooze', 'auto_dismiss', 'action', 'action_param', 'backup', 'backupDelay'];
          live.state.alarms = Array.from({ length: +f.get('n') || 0 }, (_, i) => Object.fromEntries(keys.map(k => [k, f.get(i + '_' + k) || ''])));
          live.state.volume = +f.get('v'); live.state.fade = +f.get('f');
        }
        json({ ok: true });
      });
      return true;
    }
    if (a === 'sys') return json(live.sys);
    if (a === 'state') return json(live.state);
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
  if (scene === 'skipped' && a === 'state') return json({ ...data.state, skipped: nextWork() });
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
// And /api/tv/screen-live, a short canned H.264 stream of a drawn home screen, sent at 30 frames a second, looping.
function tvPose(q, s) {
  const fs = require('fs');
  const json = v => { s.setHeader('content-type', 'application/json'); s.end(typeof v === 'string' ? v : JSON.stringify(v)); return true; };
  const scene = (q.url.match(/^\/(tour|flickstream|blankbanner|cold)(?=\/)/) || [])[1];
  if (scene) q.url = q.url.slice(scene.length + 1);
  const path = q.url.split('?')[0], query = new URL(q.url, 'http://x').searchParams;
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
  if (path === '/api/tv/shot' && q.url !== '/api/tv/shot') { s.setHeader('content-type', 'image/jpeg'); s.end(fs.readFileSync(__dirname + '/shot.jpg')); return true; }
  if (/^\/art[0-2]\.png$/.test(path)) {
    const tones = [[[200, 60, 40], [40, 20, 90]], [[30, 150, 110], [10, 40, 60]], [[230, 190, 60], [120, 30, 120]]][+path[4]];
    s.setHeader('content-type', 'image/png'); s.end(png(300, 300, tones[0], tones[1])); return true;
  }
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
    s.writeHead(200, { 'content-type': 'video/h264', 'cache-control': 'no-store' });
    let n = 0;
    const timer = setInterval(() => { s.write(tvPose.units[n % tvPose.units.length]); n++; }, 33);
    q.on('close', () => clearInterval(timer));
    return true;
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

// A stand-in for the Mac's Screen Sharing behind the dashboard's bridge, for the Mac Pro app's measuring shots of the
// remote screen: the bridge's handshake, then a page of lyrics that scrolls a little every 16 ms, sent as raw pixels.
// Every answer is held back 45 ms, about a trip over Tailscale, so asking for one picture at a time shows what it costs.
// It logs how many pictures a second it sends.
function mockScreen(req, sock) {
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
  const later = data => setTimeout(() => frame(data), LAG);
  // BGRX, as the app asks for: 32 bits, little-endian, red at 16.
  const px = (r, g, b) => { const p = Buffer.alloc(4); p.writeUInt32LE((r << 16) | (g << 8) | b); return p; };
  const bg = px(28, 22, 44), bright = px(235, 235, 245), dim = px(120, 110, 150), side = px(18, 18, 22);
  const band = { x: 240, y: 120, w: 800, h: 560 };
  const paint = (x0, y0, w, h, scroll) => {
    const out = Buffer.alloc(w * h * 4);
    for (let y = 0; y < h; y++) {
      const Y = y0 + y, row = y * w * 4;
      if (Y < band.y || Y >= band.y + band.h) { out.fill(side, row, row + w * 4); continue; }
      out.fill(bg, row, row + w * 4);
      // A line every 56 px, 22 px tall and of varying length; the one in the middle bright, the rest dim.
      const v = Y - band.y + scroll, k = Math.floor(v / 56);
      if (v % 56 >= 22) continue;
      const len = 260 + ((k * 137) % 420), mid = Math.abs(Y - (band.y + band.h / 2)) < 30;
      const from = Math.max(x0, band.x + 40), to = Math.min(x0 + w, band.x + 40 + len);
      if (to > from) out.fill(mid ? bright : dim, row + (from - x0) * 4, row + (to - x0) * 4);
    }
    return out;
  };
  const update = (x, y, w, h, scroll) => {
    const head = Buffer.alloc(16);
    head.writeUInt16BE(1, 2);
    head.writeUInt16BE(x, 4); head.writeUInt16BE(y, 6); head.writeUInt16BE(w, 8); head.writeUInt16BE(h, 10); head.writeInt32BE(0, 12);
    return Buffer.concat([head, paint(x, y, w, h, scroll)]);
  };
  let stage = 0, pending = 0, scroll = 0, sent = -1, count = 0, buf = Buffer.alloc(0), msgs = Buffer.alloc(0);
  // Like a real server: an answer goes out when there's a request waiting and the page has moved since the last one.
  const answer = () => { if (pending > 0 && sent !== scroll) { pending--; sent = scroll; count++; later(update(band.x, band.y, band.w, band.h, scroll)); } };
  const tick = setInterval(() => { scroll += 3; answer(); }, 16);
  const report = setInterval(() => { if (count) console.log(`mock screen: ${Math.round(count / 2)} pictures a second`); count = 0; }, 2000);
  const stop = () => { clearInterval(tick); clearInterval(report); sock.destroy(); };
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
      if (t === 3) {
        if (m[1] === 0) { count++; sent = scroll; later(update(0, 0, W, H, scroll)); }
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
