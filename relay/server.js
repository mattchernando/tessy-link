'use strict';
// Tessy Link relay — pairs a Mac ("host") with one or more Tesla browsers
// ("viewers") by a short numeric code, and forwards video frames one way and
// input events the other. Video bandwidth flows through this server, so run it
// somewhere with decent bandwidth.

const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8080;
const PAGE = fs.readFileSync(path.join(__dirname, 'public', 'index.html'));

const server = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (url === '/' || url === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(PAGE);
  } else if (url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ok');
  } else {
    res.writeHead(404); res.end('not found');
  }
});

const wss = new WebSocketServer({ server, maxPayload: 16 * 1024 * 1024 });

// code -> { host: ws|null, viewers: Set<ws> }
const rooms = new Map();
function getRoom(code) {
  let r = rooms.get(code);
  if (!r) { r = { host: null, viewers: new Set() }; rooms.set(code, r); }
  return r;
}
function sendJSON(ws, obj) { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); }

wss.on('connection', (ws) => {
  ws.role = null;
  ws.code = null;
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (data, isBinary) => {
    // First message must be a JSON hello identifying role + code.
    if (ws.role === null) {
      let msg;
      try { msg = JSON.parse(data.toString()); } catch { ws.close(); return; }
      const code = String(msg.code || '').trim();
      if (!/^[0-9]{4,8}$/.test(code)) { sendJSON(ws, { type: 'error', error: 'bad-code' }); ws.close(); return; }
      ws.code = code;
      const room = getRoom(code);
      if (msg.role === 'host') {
        if (room.host && room.host.readyState === 1) { sendJSON(ws, { type: 'error', error: 'code-in-use' }); ws.close(); return; }
        ws.role = 'host';
        room.host = ws;
        sendJSON(ws, { type: 'ready', role: 'host', viewers: room.viewers.size });
        console.log(`host joined code=${code}`);
      } else if (msg.role === 'view') {
        ws.role = 'view';
        room.viewers.add(ws);
        const hostPresent = !!(room.host && room.host.readyState === 1);
        sendJSON(ws, { type: 'ready', role: 'view', hostPresent });
        if (hostPresent) sendJSON(room.host, { type: 'viewer-joined', viewers: room.viewers.size });
        console.log(`viewer joined code=${code} hostPresent=${hostPresent}`);
      } else {
        ws.close();
      }
      return;
    }

    const room = rooms.get(ws.code);
    if (!room) return;

    if (ws.role === 'host') {
      // Host -> viewers: binary video frames (and any control text).
      for (const v of room.viewers) if (v.readyState === 1) v.send(data, { binary: isBinary });
    } else if (ws.role === 'view') {
      // Viewer -> host: input events (text JSON).
      if (room.host && room.host.readyState === 1) room.host.send(data, { binary: isBinary });
    }
  });

  ws.on('close', () => {
    const room = ws.code && rooms.get(ws.code);
    if (!room) return;
    if (ws.role === 'host' && room.host === ws) {
      room.host = null;
      for (const v of room.viewers) sendJSON(v, { type: 'host-gone' });
    } else if (ws.role === 'view') {
      room.viewers.delete(ws);
      if (room.host) sendJSON(room.host, { type: 'viewer-left', viewers: room.viewers.size });
    }
    if (!room.host && room.viewers.size === 0) rooms.delete(ws.code);
  });
});

// Heartbeat: drop dead sockets.
const interval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) return ws.terminate();
    ws.isAlive = false;
    try { ws.ping(); } catch {}
  });
}, 30000);
wss.on('close', () => clearInterval(interval));

server.listen(PORT, () => console.log(`Tessy Link relay listening on :${PORT}`));
