# Tessy Link relay — Cloudflare Workers + Durable Objects

The recommended way to host the relay: free on Cloudflare's plan, and Cloudflare
does not bill egress bandwidth (the usual cost of relaying video). One Durable
Object pairs a Mac with Tesla browsers by code; same wire protocol as the Node
relay.

## Deploy

```bash
cd relay-cloudflare
npm install
npx wrangler login       # opens the browser to your Cloudflare account (free)
npx wrangler deploy
```

Wrangler prints your URL, e.g. `https://tessy-link-relay.<your-subdomain>.workers.dev`.
In the Tessy Link menu: **Mode ▸ Set relay URL…** and paste that URL.

## Local test

```bash
npm install
npx wrangler dev         # serves on http://localhost:8787
```

Then point the app at `ws://localhost:8787/` (Mode ▸ Set relay URL…) or open
`http://localhost:8787/` in a browser and enter the code.

## Cost

Free plan includes SQLite-backed Durable Objects: 100,000 requests/day and
13,000 GB-s/day. Incoming WebSocket messages are billed 20:1 (100 messages = 5
requests); outgoing messages are free; egress bandwidth is not billed. At ~15
fps that's roughly 2–3k billed requests and a few hundred GB-s per hour of
streaming — comfortably within the free budget for personal use.

## Custom domain (optional)

Add a route in `wrangler.toml` or bind a custom domain in the Cloudflare
dashboard to get `relay.yourdomain.com` instead of the `workers.dev` URL.
