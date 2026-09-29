# Kitty push relay

End users never touch Apple developer accounts. You — the app's developer — run this small
Cloudflare Worker once with your APNs key; every user's phone registers with it, and every user's
own Hermes gateway posts **encrypted** notifications to it. The relay sees device tokens and
ciphertext only; the app's Notification Service Extension decrypts on the phone.

```
phone  ──register (install id + secret)──▶  relay (KV: token, bundle, env)
gateway ──POST /v1/push {install id, secret, enc}──▶  relay ──▶ APNs ──▶ phone (NSE decrypts enc)
```

The install id, the secret and the AES key are minted by the app and written to the user's own
gateway (`<profile home>/push/devices/…json`); nothing but the encrypted payload ever leaves
the user's machine.

## Deploy (once)

```bash
cd server/push-relay
npm i -g wrangler && wrangler login
wrangler kv namespace create DEVICES          # put the id in wrangler.toml
wrangler secret put APNS_KEY_P8               # paste the .p8 contents
wrangler secret put APNS_KEY_ID
wrangler secret put APNS_TEAM_ID
wrangler deploy                               # → https://kitty-push-relay.<you>.workers.dev
```

Then set `KITTY_PUSH_RELAY_URL=https://…workers.dev` in `Tools/release/.env`; the release script
bakes it into the app's Info.plist (`KittyPushRelayURL`). Builds without it fall back to the
bring-your-own-APNs-key flow.

## Live Activities and complications

Live Activity updates cannot be decrypted by an extension, so in relay mode the gateway sends only
generic content-state text ("Working…", "Waiting for you"); titles and details stay in the app.
Watch complications get content-available pushes (no content at all).
