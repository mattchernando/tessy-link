'use strict';
// Exercises the relay's pairing + forwarding logic end-to-end in-process.
process.env.PORT = '8099';
require('./server.js');
const WebSocket = require('ws');

const URL = 'ws://127.0.0.1:8099/';
const results = [];
function check(name, cond) { results.push([name, !!cond]); console.log((cond ? 'PASS ' : 'FAIL ') + name); }
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
function open() { return new Promise((res) => { const ws = new WebSocket(URL); ws.on('open', () => res(ws)); }); }
function next(ws) { return new Promise((res) => ws.once('message', (d, isBin) => res({ d, isBin }))); }

(async () => {
  await wait(400);

  // 1. Host joins.
  const host = await open();
  host.send(JSON.stringify({ role: 'host', code: '123456' }));
  let m = JSON.parse((await next(host)).d.toString());
  check('host gets ready', m.type === 'ready' && m.role === 'host');

  // 2. Viewer joins same code; host notified.
  const viewer = await open();
  const hostNotified = next(host);
  viewer.send(JSON.stringify({ role: 'view', code: '123456' }));
  m = JSON.parse((await next(viewer)).d.toString());
  check('viewer ready + host present', m.type === 'ready' && m.hostPresent === true);
  const hn = JSON.parse((await hostNotified).d.toString());
  check('host notified of viewer', hn.type === 'viewer-joined');

  // 3. Host video frame (binary) reaches viewer intact.
  const frame = Buffer.from([0xff, 0xd8, 0xff, 0x01, 0x02, 0x03, 0xff, 0xd9]);
  const gotFrame = next(viewer);
  host.send(frame);
  const fr = await gotFrame;
  check('viewer receives binary frame', fr.isBin && Buffer.compare(Buffer.from(fr.d), frame) === 0);

  // 4. Viewer input (text) reaches host.
  const gotInput = next(host);
  viewer.send(JSON.stringify({ type: 'down', x: 0.5, y: 0.5 }));
  const inp = JSON.parse((await gotInput).d.toString());
  check('host receives input event', inp.type === 'down' && inp.x === 0.5);

  // 5. Wrong code viewer sees no host.
  const stray = await open();
  stray.send(JSON.stringify({ role: 'view', code: '999999' }));
  m = JSON.parse((await next(stray)).d.toString());
  check('stray code has no host', m.type === 'ready' && m.hostPresent === false);

  // 6. Duplicate host on same code is rejected.
  const host2 = await open();
  host2.send(JSON.stringify({ role: 'host', code: '123456' }));
  m = JSON.parse((await next(host2)).d.toString());
  check('duplicate host rejected', m.type === 'error' && m.error === 'code-in-use');

  // 7. Bad code format rejected.
  const bad = await open();
  bad.send(JSON.stringify({ role: 'host', code: 'abc' }));
  m = JSON.parse((await next(bad)).d.toString());
  check('bad code rejected', m.type === 'error' && m.error === 'bad-code');

  const failed = results.filter(([, ok]) => !ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  process.exit(failed === 0 ? 0 : 1);
})();
