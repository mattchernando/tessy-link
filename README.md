# Tessy Link

Use your Tesla's touchscreen (or any device with a web browser) as a wireless
**extended monitor** for your Mac — free, no hardware, no cables. A menu-bar app
creates a virtual display, streams it to a browser, and lets you **touch the
Tesla screen to control the Mac**.

Two ways to connect:

- **Shared relay** *(default)* — everyone points their browser at one stable
  link and types a **pairing code** shown on their Mac. The code locks your
  screen to your Mac, so a stray link alone gets nobody in. Needs a small relay
  server you host (see below).
- **Local tunnel** — each Mac spins up its own free [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/)
  quick tunnel. No server to host, but the link is random and changes each run.

## How it works

macOS side (`mac/`): a menu-bar app creates a **virtual display** via Apple's
private `CGVirtualDisplay` API (the same approach BetterDummy/FreeDisplay use),
captures it with **ScreenCaptureKit**, and JPEG-encodes frames. In relay mode it
opens a WebSocket to the relay and pushes frames; in local mode it serves them as
MJPEG behind a cloudflared tunnel. Touch/scroll events come back and are posted as
real `CGEvents`.

Relay side (`relay/`): a tiny dependency-light Node server pairs a Mac ("host")
with browsers ("viewers") by numeric code and forwards frames one way, input the
other. Video flows *through* the relay, so host it somewhere with real bandwidth.

```
Mac app ──frames──▶ Relay ──frames──▶ Tesla browser
        ◀──input──       ◀──input──
                    (paired by code)
```

## Repo layout

```
mac/               Swift menu-bar app (SwiftPM). Build with `swift build`.
relay-cloudflare/  Relay as a Cloudflare Worker + Durable Object (recommended host).
relay/             Same relay as a plain Node server (Render/Fly/Docker/VPS).
```

## Build the Mac app

Requires macOS 13+ and Xcode command-line tools (`xcode-select --install`).

```bash
cd mac
swift build -c release
./package_app.sh          # assembles a signed "Tessy Link.app"
cp -R "Tessy Link.app" /Applications/
open "/Applications/Tessy Link.app"
```

First run, macOS asks for **Screen Recording** (to capture — allow, then relaunch)
and, on your first tap, **Accessibility** (to control). Optional for local mode:
`brew install cloudflared`.

## Deploy the relay

**Recommended — Cloudflare Workers + Durable Objects** (`relay-cloudflare/`):
free plan, no egress bandwidth billing, no server to keep alive, stable URL.

```bash
cd relay-cloudflare
npm install
npx wrangler login
npx wrangler deploy      # prints https://tessy-link-relay.<you>.workers.dev
```

The rest of this section covers the Node relay (`relay/`) if you'd rather host it
yourself. Any host that runs Node 18+ or Docker works.

**Render** (free tier, sleeps when idle): create a new Web Service from this repo
— it reads `relay/render.yaml`. Your link becomes `https://<name>.onrender.com`.

**Fly.io**:

```bash
cd relay
fly launch --copy-config --now
```

**Any VPS / Docker host**:

```bash
cd relay
docker build -t tessy-relay .
docker run -d -p 80:8080 --restart unless-stopped tessy-relay
```

> Video streaming uses real bandwidth. Free tiers are fine for light personal use;
> a ~$5/mo VPS is the reliable option for regular use.

## Use it

1. In the app menu: **Mode ▸ Shared relay**, then **Mode ▸ Set relay URL…** and
   paste your relay's address (`https://…` — it's converted to `wss://`).
2. Click **Start**. The menu shows a 6-digit **Code**.
3. In the parked Tesla (on its own internet — premium connectivity or a phone
   hotspot), open your relay link, enter the code, and connect. Drag Mac windows
   onto the new display; tap and scroll on the Tesla screen to control them.

Use **New code** any time to rotate the pairing code.

## Security notes

The pairing code gates access: a viewer must present the same code the host
registered. Treat the code like a short-lived password — anyone who has your
relay link *and* your current code can see and control your screen while a session
is live. Rotate it with **New code**, and stop the session when you're done. The
relay does not persist frames or codes; rooms vanish when both sides disconnect.

## Limits

- The Tesla browser only runs while parked and keeps the screen awake.
- MJPEG latency is ~150–350 ms — great for docs, email, dashboards, terminals;
  not for video or gaming. A WebCodecs/H.264 path is a natural future upgrade.
- No audio; DRM-protected video won't capture.
- The macOS virtual display uses undocumented Apple APIs; a future macOS could
  change them. The app fails gracefully if the private classes disappear.

## License

MIT — see [LICENSE](LICENSE).
