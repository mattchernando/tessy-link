// Tessy Link relay — Cloudflare Worker + Durable Object.
// Pairs a Mac (host) with Tesla browsers (viewers) by code, forwards frames one
// way and input the other, and relays video-format capability (H.264/WebCodecs).

import PAGE_HTML from "./index.html";

export default {
  async fetch(request, env) {
    if ((request.headers.get("Upgrade") || "").toLowerCase() === "websocket") {
      const id = env.RELAY.idFromName("relay");
      return env.RELAY.get(id).fetch(request);
    }
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return new Response("ok");
    return new Response(PAGE_HTML, {
      headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
    });
  },
};

export class Relay {
  constructor(state, env) {
    this.rooms = new Map(); // code -> { host: ws|null, viewers: Set<ws> }
  }
  getRoom(code) {
    let r = this.rooms.get(code);
    if (!r) { r = { host: null, viewers: new Set() }; this.rooms.set(code, r); }
    return r;
  }

  async fetch(request) {
    const pair = new WebSocketPair();
    const client = pair[0], server = pair[1];
    server.accept();
    const conn = { role: null, code: null };
    const send = (ws, obj) => { try { ws.send(JSON.stringify(obj)); } catch {} };

    server.addEventListener("message", (ev) => {
      const data = ev.data;
      if (conn.role === null) {
        let msg;
        try { msg = JSON.parse(typeof data === "string" ? data : ""); } catch { server.close(); return; }
        const code = String((msg && msg.code) || "").trim();
        if (!/^[0-9]{4,8}$/.test(code)) { send(server, { type: "error", error: "bad-code" }); server.close(); return; }
        conn.code = code;
        const room = this.getRoom(code);
        if (msg.role === "host") {
          if (room.host) { send(server, { type: "error", error: "code-in-use" }); server.close(); return; }
          conn.role = "host"; room.host = server;
          send(server, { type: "ready", role: "host" });
          // Tell the host about any viewers already waiting (and their caps).
          for (const v of room.viewers) send(server, { type: "viewer-joined", h264: !!v._h264 });
        } else if (msg.role === "view") {
          conn.role = "view"; server._h264 = msg.h264 === true;
          room.viewers.add(server);
          const hostPresent = !!room.host;
          send(server, { type: "ready", role: "view", hostPresent });
          if (hostPresent) send(room.host, { type: "viewer-joined", h264: server._h264 });
        } else { server.close(); }
        return;
      }
      const room = this.rooms.get(conn.code);
      if (!room) return;
      if (conn.role === "host") {
        for (const v of room.viewers) { try { v.send(data); } catch {} }
      } else if (conn.role === "view") {
        if (room.host) { try { room.host.send(data); } catch {} }
      }
    });

    const cleanup = () => {
      const room = conn.code && this.rooms.get(conn.code);
      if (!room) return;
      if (conn.role === "host" && room.host === server) {
        room.host = null;
        for (const v of room.viewers) send(v, { type: "host-gone" });
      } else if (conn.role === "view") {
        room.viewers.delete(server);
        if (room.host) send(room.host, { type: "viewer-left" });
      }
      if (!room.host && room.viewers.size === 0) this.rooms.delete(conn.code);
    };
    server.addEventListener("close", cleanup);
    server.addEventListener("error", cleanup);
    return new Response(null, { status: 101, webSocket: client });
  }
}
