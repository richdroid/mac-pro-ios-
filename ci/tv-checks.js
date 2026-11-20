// Checks on what the TV app is given in the build, logged as warnings, never failing it:
//  - a banner with nothing in it (its brightness hardly varies over a 16 by 16 grid, as with YouTube Music's white logo
//    flattened onto white). The app draws its own banner then, but the asset itself wants fixing on the Mac.
//  - a Watch shelf of fewer than 8 (Continue watching aside). The app folds those into the row before, but the bridge
//    should send full rows.
// Run with the mock answering on 9002.
const http = require('http'), zlib = require('zlib');
const get = path => new Promise((ok, no) => http.get('http://127.0.0.1:9002' + path, r => { const b = []; r.on('data', c => b.push(c)); r.on('end', () => ok(Buffer.concat(b))); }).on('error', no));
const warn = m => console.log('::warning::' + m);

// Enough of PNG for these banners: 8-bit grey, RGB, palette, grey with alpha and RGBA, not interlaced.
function pixels(buf) {
  let at = 8, w, h, depth, type, lace, plte, trns; const idat = [];
  while (at < buf.length) {
    const n = buf.readUInt32BE(at), kind = buf.toString('ascii', at + 4, at + 8), d = buf.subarray(at + 8, at + 8 + n);
    if (kind === 'IHDR') { w = d.readUInt32BE(0); h = d.readUInt32BE(4); depth = d[8]; type = d[9]; lace = d[12]; }
    if (kind === 'PLTE') plte = d;
    if (kind === 'tRNS') trns = d;
    if (kind === 'IDAT') idat.push(d);
    at += 12 + n;
  }
  if (depth !== 8 || lace) return null;
  const ch = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[type], stride = w * ch, raw = zlib.inflateSync(Buffer.concat(idat)), px = Buffer.alloc(stride * h);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)], line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= ch ? px[y * stride + x - ch] : 0, b = y > 0 ? px[(y - 1) * stride + x] : 0, c = x >= ch && y > 0 ? px[(y - 1) * stride + x - ch] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][f];
      px[y * stride + x] = (line[x] + pred) & 255;
    }
  }
  // Each pixel as brightness 0 to 1, see-through parts taken as the black a wide banner sits on.
  return { w, h, at: (x, y) => {
    const i = (y * w + x) * ch;
    let r, g, b, al = 1;
    if (type === 3) { const k = px[i]; r = plte[k * 3]; g = plte[k * 3 + 1]; b = plte[k * 3 + 2]; if (trns && k < trns.length) al = trns[k] / 255; }
    else if (type === 0 || type === 4) { r = g = b = px[i]; if (type === 4) al = px[i + 1] / 255; }
    else { r = px[i]; g = px[i + 1]; b = px[i + 2]; if (type === 6) al = px[i + 3] / 255; }
    return al * (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  } };
}
function spread(img) {
  const v = [];
  for (let gy = 0; gy < 16; gy++) for (let gx = 0; gx < 16; gx++) v.push(img.at(Math.floor((gx + 0.5) * img.w / 16), Math.floor((gy + 0.5) * img.h / 16)));
  const mean = v.reduce((a, b) => a + b, 0) / v.length;
  return Math.sqrt(v.reduce((a, b) => a + (b - mean) ** 2, 0) / v.length);
}

(async () => {
  try {
    const status = JSON.parse(await get('/api/tv/status'));
    for (const app of status.apps || []) {
      if (!app.hasIcon) continue;
      const img = pixels(await get('/api/tv/icon?pkg=' + app.pkg + '&v=2'));
      if (!img) { console.log('banner ' + app.pkg + ': not a kind this check reads'); continue; }
      const s = spread(img);
      console.log('banner ' + app.pkg + ' spread ' + s.toFixed(3));
      if (s < 0.04) warn(`The ${app.name} banner is blank (brightness spread ${(s * 100).toFixed(1)} %). The app shows its own drawn banner instead; fix the asset on the Mac.`);
    }
    for (const type of ['movie', 'series']) {
      const rows = JSON.parse(await get('/api/tv/discover?type=' + type)).rows || [];
      for (const r of rows) {
        console.log(`row ${type} "${r.title}" ${r.items.length}`);
        if (r.title !== 'Continue watching' && r.items.length < 8) warn(`Watch (${type === 'movie' ? 'films' : 'shows'}): "${r.title}" has only ${r.items.length}. The app folds it into the row before; the bridge should send it full or not at all.`);
      }
    }
  } catch (e) { warn('TV checks could not run: ' + e.message); }
})();
