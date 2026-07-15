# Tessy Link

Turn your Tesla's touchscreen — or any device with a web browser — into a
wireless **extended monitor** for your Mac. Free, no hardware, no cables. A
menu‑bar app creates a virtual display, streams it as **H.264** (with an MJPEG
fallback), and lets you **touch the screen to control the Mac**, and automatically **fits the display to your Tesla's screen** (no black bars).

You connect by opening a link and typing a short **pairing code**. The code locks
your screen to your Mac, so a stray link alone gets nobody in.

---

## Install (macOS — no build needed)

Paste this into Terminal:

```bash
curl -fsSL https://tessylink.hernandomediallc.com/install | bash
```

It downloads the latest app, installs it to Applications, clears the download
quarantine (so there's no "unidentified developer" wall), and launches it. Then:

1. Click the menu‑bar **display icon** → **Start**, and allow **Screen Recording**
   (the app relaunches once for it to take effect).
2. Open **https://tessylink.hernandomediallc.com**, enter the **Code** shown in the
   menu, and drag a window onto the new display (to the right of your main screen).

That's the whole thing. Your Code keeps your session private.

> First launch alternative: if you'd rather not run a script, download
> `Tessy-Link.zip` from [Releases](https://github.com/mattchernando/tessy-link/releases/latest),
> unzip it, right‑click **Tessy Link.app** → **Open** (once) to get past Gatekeeper,
> and drag it to Applications.

---

## Build from source (optional)

The easiest path: build the app and use the relay that's already deployed at
**`tessylink.hernandomediallc.com`** — nothing to host, no account to create. The
app points at it by default.

**Requirements:** macOS 13+ and Xcode command‑line tools
(`xcode-select --install`).

```bash
git clone https://github.com/mattchernando/tessy-link.git
cd tessy-link/mac
swift build -c release
./package_app.sh                 # builds "Tessy Link.app"
cp -R "Tessy Link.app" /Applications/
open "/Applications/Tessy Link.app"
```

Then:

1. First launch, macOS asks for **Screen Recording** — allow it, then relaunch the
   app once (screen recording only activates after a restart). **Accessibility** is
   requested the first time you tap, to enable touch control.
2. Click the **display icon** in the menu bar → **Start**. It's already set to the
   shared relay, so a **8‑digit Code** appears in the menu.
3. In the parked Tesla — on its own internet (premium connectivity or a phone
   hotspot) — or in any browser, open **https://tessylink.hernandomediallc.com**,
   enter the **Code**, and drag a window onto the new display (it sits to the right
   of your main screen).

Your Code keeps your session private; everyone using the shared relay is isolated
by their own code. Use **New code** in the menu to rotate it, and **Stop** when
you're done.

> **Heads‑up on the shared relay:** your video is relayed through the maintainer's
> Cloudflare account and free‑tier quota. That's fine for personal use — but if you
> use it heavily, or want guaranteed availability and privacy, **host your own**
> (it's free too; see below) and point the app at it with **Mode ▸ Set relay URL…**.

---

## How it works

**macOS side (`mac/`):** a menu‑bar app creates a **virtual display** via Apple's
private `CGVirtualDisplay` API (the same approach BetterDummy/FreeDisplay use),
captures it with **ScreenCaptureKit**, and encodes frames with **VideoToolbox
(H.264)**. It opens a WebSocket to the relay, registers a pairing code, streams
video out, and posts incoming touch/scroll events as real `CGEvents`.

**Relay side (`relay-cloudflare/`):** a small **Cloudflare Worker + Durable
Object** pairs a Mac ("host") with browsers ("viewers") by code, forwarding video
one way and input the other. Video flows *through* the relay — Cloudflare doesn't
bill egress, which is what makes a video relay free.

**Browser side:** modern browsers decode the H.264 with the **WebCodecs** API and
render to a canvas. Browsers without WebCodecs automatically fall back to **MJPEG**,
so it still works on older Tesla MCUs. The receiver reports its viewport size and
the app resizes the virtual display to match — filling the screen with no
letterboxing, and re‑fitting when you switch the browser between half‑ and
full‑screen.

```
Mac app ──H.264──▶ Cloudflare relay ──H.264──▶ browser (WebCodecs → canvas)
        ◀──input──                  ◀──input──
                     (paired by 8‑digit code)
```

---

## Privacy & the pairing code

The pairing code is the security boundary. A viewer must present the same code the
host registered, and the relay refuses a second host on a code that's already in
use. Treat the code like a short‑lived password: anyone who has your relay link
**and** your current code can see and control your screen while a session is live.
Rotate it with **New code**, and **Stop** the session when finished. The relay
stores nothing — rooms vanish when both sides disconnect.

The relay is hardened against code guessing: **8‑digit codes**, **per‑IP rate
limiting**, and viewer/room caps. Injected touch input is **clamped to the virtual
display**, so a viewer can't reach the rest of your Mac.

---

## Host your own relay (optional, free)

Running your own relay gives you a private, dedicated link and your own quota.

**Cloudflare Workers + Durable Objects (recommended):**

```bash
cd relay-cloudflare
npm install
npx wrangler login
npx wrangler deploy      # prints https://tessy-link-relay.<you>.workers.dev
```

To use a custom domain you own on Cloudflare, add it under `routes` in
`wrangler.toml` (see the example already there for `tessylink.hernandomediallc.com`).

**Plain Node / Docker (`relay/`)** — for Render, Fly.io, or any VPS:

```bash
cd relay
npm install && npm start          # local, on :8080
# or
docker build -t tessy-relay . && docker run -d -p 80:8080 tessy-relay
```

Config files for Render (`render.yaml`) and Fly (`fly.toml`) are included.

Then in the app: **Mode ▸ Set relay URL…** and paste your relay's address
(`https://…` is converted to `wss://` automatically).

---

## Build notes

- `./package_app.sh` compiles a release build and assembles a signed
  `Tessy Link.app` (menu‑bar only, custom icon). By default it signs **ad‑hoc**,
  which means macOS asks for Screen Recording again after each rebuild. To make
  permissions persist across rebuilds, sign with a stable self‑signed certificate
  (create one in Keychain Access → Certificate Assistant, "Code Signing"), then set
  its name in `package_app.sh`.
- Regenerate the icon with `python3 gen_icon.py` (needs Pillow).

---

## Menu options

- **Mode** — Shared relay (type a code) or Local tunnel (per‑Mac
  [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/)),
  plus **Set relay URL…**
- **Auto‑fit to viewer's screen** — on by default; resizes the display to the
  Tesla's shape so it fills edge‑to‑edge (re‑fits on half↔full changes)
- **Resolution** — a starting size, used until the Tesla reports its screen;
  streamed at up to ~1440px for efficiency
- **Touch control** — enable/disable input from the browser
- **Quality / Frame rate**
- **Code / New code** — the 8‑digit pairing code (**New code** rotates it)
- **Show QR code**

---

## Limits

- The Tesla browser only runs while parked, and keeps the screen awake (some
  battery drain over long sessions).
- Latency is low with H.264 and great for docs, dashboards, email, terminals. A
  static screen refreshes about once a second; any motion is smooth.
- No audio; DRM‑protected video (Netflix, etc.) won't capture.
- The macOS virtual display uses undocumented Apple APIs; a future macOS could
  change them. The app fails gracefully if the private classes disappear.

---

## Repo layout

```
mac/               Swift menu-bar app (SwiftPM)
relay-cloudflare/  Relay as a Cloudflare Worker + Durable Object (recommended host)
relay/             Same relay as a plain Node server (Render/Fly/Docker)
```

## License

MIT — see [LICENSE](LICENSE).
