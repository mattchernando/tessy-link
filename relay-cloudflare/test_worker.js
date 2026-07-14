'use strict';
// Connects a host + viewer to a running relay (wrangler dev) and checks pairing,
// frame forwarding, and input forwarding. Usage: node test_worker.js [wsURL]
const WebSocket = require('ws');
const URL = process.argv[2] || 'ws://127.0.0.1:8787/';
const results = [];
const check = (n, c) => { results.push([n, !!c]); console.log((c ? 'PASS ' : 'FAIL ') + n); };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const open = () => new Promise((res) => { const ws = new WebSocket(URL); ws.on('open', () => res(ws)); });
const next = (ws) => new Promise((res) => ws.once('message', (d, isBin) => res({ d, isBin })));

(async () => {
  const host = await open();
  host.send(JSON.stringify({ role: 'host', code: '246810' }));
  let m = JSON.parse((await next(host)).d.toString());
  check('host ready', m.type === 'ready' && m.role === 'host');

  const viewer = await open();
  const hostNotified = next(host);
  viewer.send(JSON.stringify({ role: 'view', code: '246810' }));
  m = JSON.parse((await next(viewer)).d.toString());
  check('viewer ready + host present', m.type === 'ready' && m.hostPresent === true);
  check('host notified', JSON.parse((await hostNotified).d.toString()).type === 'viewer-joined');

  const frame = Buffer.from([0xff, 0xd8, 0xff, 0x0a, 0x0b, 0xff, 0xd9]);
  const gotFrame = next(viewer);
  host.send(frame);
  const fr = await gotFrame;
  check('viewer got binary frame', fr.isBin && Buffer.compare(Buffer.from(fr.d), frame) === 0);

  const gotInput = next(host);
  viewer.send(JSON.stringify({ type: 'move', x: 0.1, y: 0.2 }));
  const inp = JSON.parse((await gotInput).d.toString());
  check('host got input', inp.type === 'move' && inp.x === 0.1);

  const stray = await open();
  stray.send(JSON.stringify({ role: 'view', code: '111111' }));
  m = JSON.parse((await next(stray)).d.toString());
  check('stray code no host', m.type === 'ready' && m.hostPresent === false);

  await wait(100);
  const failed = results.filter(([, ok]) => !ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
