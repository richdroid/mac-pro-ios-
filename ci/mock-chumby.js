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
const macStatus = require('fs').readFileSync(__dirname + '/mock-status.json');
http.createServer((q, s) => { s.setHeader('content-type', 'application/json'); s.end(q.url === '/api/status' ? macStatus : '{}'); }).listen(9001, '127.0.0.1');
