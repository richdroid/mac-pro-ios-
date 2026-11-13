// A stand-in Stremio for the build's films of Play on iPhone: its API (login, add-ons, library), one add-on of samples,
// a catalogue's meta, and the sample files themselves, generated in CI (a test pattern and tones: nothing real, no
// account, no stream from anywhere). Every library write is logged to /tmp/stremio-puts.log so the films' resume can be
// checked against what the app wrote.
//   node ci/mock-stremio.js [port=9083] [media dir=/tmp/stremio-media]
const http = require('http'), fs = require('fs'), path = require('path');
const PORT = +(process.argv[2] || 9083), MEDIA = process.argv[3] || '/tmp/stremio-media';
const BASE = `http://127.0.0.1:${PORT}`;
const KEY = 'sample-auth-key';
const now = () => new Date().toISOString();
// The library as the TV left it: the sample film part way through (1:35 of 10:00), so the phone's picker offers to
// resume there.
const library = {
  tt0000001: { _id: 'tt0000001', name: 'Sample Film', type: 'movie', poster: '', posterShape: 'poster', removed: false, temp: false,
    _ctime: now(), _mtime: now(),
    state: { lastWatched: now(), timeWatched: 95000, timeOffset: 95000, overallTimeWatched: 95000, timesWatched: 0, flaggedWatched: 0,
      duration: 600000, video_id: 'tt0000001', watched: null, noNotif: false },
    behaviorHints: { defaultVideoId: null, featuredVideoId: null, hasScheduledVideos: false } },
};
const manifest = { id: 'local.sample.streams', version: '1.0.0', name: 'Sample add-on', resources: ['stream'], types: ['movie', 'series'], idPrefixes: ['tt'], catalogs: [] };
const metas = {
  'movie/tt0000001': { id: 'tt0000001', type: 'movie', name: 'Sample Film', poster: `${BASE}/art/poster.png`, background: '', releaseInfo: '2024', videos: [] },
  'series/tt0000002': { id: 'tt0000002', type: 'series', name: 'Sample Show', poster: `${BASE}/art/poster.png`, background: '',
    videos: [1, 2, 3].map(e => ({ id: `tt0000002:1:${e}`, season: 1, episode: e, name: `Sample Episode ${e}` })) },
};
const streamsFor = id => [
  { name: 'Sample\n4K ⚡', description: 'Sample.Film.2024.2160p.WEB-DL.x265.mkv\n💾 14.1 GB ⚙️ Sample', url: `${BASE}/media/sample.mkv?4k` },
  { name: 'Sample\n1080p ⚡', description: 'Sample.Film.2024.1080p.WEB-DL.x265.mkv\n💾 3.2 GB ⚙️ Sample', url: `${BASE}/media/sample.mkv` },
  { name: 'Sample\n720p', description: 'Sample.Film.2024.720p.WEB-DL.x264.mp4\n💾 0.9 GB', url: `${BASE}/media/sample.mp4` },
  { name: 'Sample\n4K HDR', description: 'Sample.Film.2024.2160p.HDR.WEB-DL.mkv\n💾 18.4 GB', infoHash: '0123456789abcdef0123456789abcdef01234567', fileIdx: 0 },
];
const send = (s, code, body, type = 'application/json') => { s.statusCode = code; s.setHeader('content-type', type); s.end(typeof body === 'string' ? body : JSON.stringify(body)); };
const read = (q, f) => { let b = ''; q.on('data', c => b += c); q.on('end', () => { let j = {}; try { j = JSON.parse(b || '{}'); } catch {} f(j); }); };
function media(q, s, file, type) {
  let st; try { st = fs.statSync(file); } catch { return send(s, 404, 'no sample', 'text/plain'); }
  const m = /bytes=(\d*)-(\d*)/.exec(q.headers.range || '');
  s.setHeader('accept-ranges', 'bytes'); s.setHeader('content-type', type);
  if (m) {
    const start = m[1] ? +m[1] : 0, end = m[2] ? Math.min(+m[2], st.size - 1) : st.size - 1;
    s.statusCode = 206; s.setHeader('content-range', `bytes ${start}-${end}/${st.size}`); s.setHeader('content-length', end - start + 1);
    if (q.method === 'HEAD') return s.end();
    return fs.createReadStream(file, { start, end }).pipe(s);
  }
  s.setHeader('content-length', st.size);
  if (q.method === 'HEAD') return s.end();
  fs.createReadStream(file).pipe(s);
}
http.createServer((q, s) => {
  const u = q.url.split('?')[0];
  if (q.method === 'POST' && u.startsWith('/api/')) return read(q.pipe ? q : q, b => {
    const method = u.slice(5);
    fs.appendFileSync('/tmp/stremio-api.log', `${now()} ${method}\n`);
    if (method === 'login') {
      if (!b.email || !b.password) return send(s, 200, { error: { message: 'Wrong email or password', code: 2 } });
      return send(s, 200, { result: { authKey: KEY, user: { email: b.email } } });
    }
    if (b.authKey !== KEY) return send(s, 200, { error: { message: 'Session does not exist', code: 1 } });
    if (method === 'logout') return send(s, 200, { result: { success: true } });
    if (method === 'addonCollectionGet') return send(s, 200, { result: { addons: [{ transportUrl: `${BASE}/addon/manifest.json`, manifest, flags: {} }] } });
    if (method === 'datastoreGet') {
      const all = Object.values(library);
      return send(s, 200, { result: b.all ? all : all.filter(i => (b.ids || []).includes(i._id)) });
    }
    if (method === 'datastorePut') {
      for (const c of b.changes || []) {
        library[c._id] = c;
        fs.appendFileSync('/tmp/stremio-puts.log', `${now()} ${c._id} ${c.state && c.state.video_id} at=${c.state && c.state.timeOffset} of=${c.state && c.state.duration} removed=${c.removed} temp=${c.temp}\n`);
      }
      return send(s, 200, { result: { success: true } });
    }
    return send(s, 200, { error: { message: 'Unknown method', code: 0 } });
  });
  if (u === '/addon/manifest.json') return send(s, 200, manifest);
  let m = /^\/addon\/stream\/(movie|series)\/(.+)\.json$/.exec(u);
  if (m) { fs.appendFileSync('/tmp/stremio-api.log', `${now()} stream ${m[1]} ${decodeURIComponent(m[2])}\n`); return setTimeout(() => send(s, 200, { streams: streamsFor(decodeURIComponent(m[2])) }), 600); }
  m = /^\/meta\/(movie|series)\/(.+)\.json$/.exec(u);
  if (m) { const meta = metas[`${m[1]}/${m[2]}`]; return send(s, meta ? 200 : 404, meta ? { meta } : { meta: null }); }
  if (u === '/media/sample.mkv') return media(q, s, path.join(MEDIA, 'sample.mkv'), 'video/x-matroska');
  if (u === '/media/sample.mp4') return media(q, s, path.join(MEDIA, 'sample.mp4'), 'video/mp4');
  if (u === '/art/poster.png') return media(q, s, path.join(MEDIA, 'poster.png'), 'image/png');
  if (u === '/library') return send(s, 200, library);
  send(s, 404, { error: 'not here' });
}).listen(PORT, '127.0.0.1', () => console.log(`stand-in Stremio on ${BASE}`));

// The stand-in Mac, through a door that writes down every send to the TV (play-stream and the like) to
// /tmp/bridge-posts.log, so the film's TV key can be checked for what it really sent. Port 9085 → 9002.
http.createServer((q, s) => {
  const chunks = [];
  q.on('data', c => chunks.push(c));
  q.on('end', () => {
    const body = Buffer.concat(chunks);
    if (q.method === 'POST') fs.appendFileSync('/tmp/bridge-posts.log', `${now()} ${q.url} ${body.toString().slice(0, 600)}\n`);
    const up = http.request({ host: '127.0.0.1', port: 9002, path: q.url, method: q.method, headers: q.headers }, r => { s.writeHead(r.statusCode, r.headers); r.pipe(s); });
    up.on('error', () => send(s, 502, { error: 'stand-in Mac down' }));
    up.end(body);
  });
}).listen(9085, '127.0.0.1');
