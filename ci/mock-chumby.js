// Sample Chumby answers so the cloud build can screenshot every tab without a real device.
const http = require('http');
const alarm = (o) => ({ name: '', enabled: '1', time: '420', when: 'weekday', type: 'beep', arg: 'Beep', param: '', param_description: 'Beep', duration: '30', snooze: '9', auto_dismiss: '0', action: '', action_param: '', backup: '1', backupDelay: '5', ...o });
const data = {
  tok: { t: 'test' },
  sys: { ok: true, up: 291000, memFree: 22000, memTotal: 62000, pspFree: 3100, load: 0.42, wifi: 71, vol: 40, shuffle: 0, airplayOn: true, chan: 'Default', cp: '1.7.3', lock: '', wall: 1, tw: ['NASA', 'BBCBreaking'], roms: ['Tetris.nes.gz', 'Super_Mario_Bros.nes'] },
  state: {
    volume: 80, fade: 30, pending: false, shuffle: 0, channel: 'Default',
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
http.createServer((q, s) => { s.setHeader('content-type', 'application/json'); if (q.url.startsWith('/api/trend')) { const now = Date.now(); return s.end(JSON.stringify({ points: Array.from({ length: 1440 }, (_, i) => { const v = 14 + 9 * Math.sin(i / 90) + 5 * Math.sin(i / 7) + (i % 211 < 12 ? 38 : 0); return { t: now - (1440 - i) * 60000, v: Math.max(1, v), peak: Math.min(100, v + 12) }; }).filter((_, i) => i < 600 || i > 660) })); } s.end(q.url === '/api/status' ? macStatus : q.url === '/api/procs' ? macProcs : '{}'); }).listen(9001, '127.0.0.1');
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
const tvApps = [['com.codex.musicwebtv', 'Mint Music', 1], ['com.mint.letterboxd', 'Letterboxd', 1], ['com.stremio.one', 'Stremio', 0], ['com.google.android.youtube.tv', 'YouTube', 1], ['com.google.android.youtube.tvmusic', 'YouTube Music', 0], ['com.netflix.ninja', 'Netflix', 1], ['com.plexapp.android', 'Plex', 1], ['com.apple.atve.androidtv.appletv', 'Apple TV', 1], ['com.android.tv.settings', 'Settings', 1], ['com.google.android.play.games', 'Google Play Games', 1], ['flar2.homebutton', 'Button Mapper', 1]];
const tvStatus = JSON.stringify({ online: true, screen: 'on', app: 'com.stremio.one', volume: 12, volumeMax: 25,
  music: { title: 'Sample Song', artist: 'Sample Artist', album: 'Sample Album', art: tvBase + '/art.png', playing: true, position: 40000, duration: 180000, sampledAt: Date.now() },
  apps: tvApps.map(([pkg, name, wide]) => ({ pkg, name, hasIcon: pkg !== 'flar2.homebutton', wide: !!wide })) });
const film = (t, more) => ({ film_slug: t.toLowerCase().replace(/[ ,]+/g, '-'), film_title: t, film_year: '1971', poster_url: tvBase + '/poster.png', ...more });
const tvFilms = JSON.stringify({ signedIn: true,
  watchlist: ['Dirty Harry', 'Chinatown', 'Heat', 'Alien', 'Ran', 'Klute', 'Thief', 'Le Samourai'].map(t => film(t, { friends_count: '4', friends_rating_avg: '3.5' })),
  friends: ['Battle Heater', 'Paris, Texas', 'Ran', 'Vertigo', 'Stalker', 'Tampopo', 'Ikiru', 'Paris, Texas'].map(t => film(t, { friend_name: 'a friend', rating: '4.0' })) });
const tvMint = JSON.stringify({ rows: ['Recently played', 'Made for you', 'New releases'].map(title => ({ title, items: ['Sample Album', 'Another Album', 'Third Album', 'Fourth Album'].map(t => ({ title: t, subtitle: 'Sample Artist', art: tvBase + '/art.png', id: 'https://music.apple.com/us/album/' + title + t, kind: 'album' })) })) });
const tvStremio = JSON.stringify({ rows: ['Popular movies', 'Popular series'].map(title => ({ title, items: ['Heat', 'Alien', 'Chinatown', 'Thief'].map((t, n) => ({ title: t, subtitle: '1995 · ★ 8.3', art: tvBase + '/poster.png', id: (title === 'Popular series' ? 'tt123456' : 'tt765432') + n, kind: title === 'Popular series' ? 'series' : 'movie', progress: t === 'Alien' ? 0.4 : undefined, about: 'A sample description of the film.' })) })) });
http.createServer((q, s) => {
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
