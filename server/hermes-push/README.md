# hermes-push — background notifications for the Hermes iOS app

The iOS app receives approvals, questions and turn events live over `/api/ws` while it is open.
For **background** delivery Apple requires a server that talks to APNs. This companion is that
server. It runs on *your* machine next to *your* Hermes install, uses *your* Apple Developer
APNs key, and never contacts anything except your gateway and Apple.

## How it works

1. The app publishes a registration file through the gateway's managed-files API:
   `<profile HERMES_HOME>/push/devices/<install-id>.json` (device token, APNs environment,
   Live Activity token, gateway URL).
2. `hermes_push.py` connects to `/api/ws` as a normal client, attaches to every live session
   (`session.active_list` → `session.activate`), and watches events.
3. When an approval / clarify / secret request is open, a turn finishes, an error fires, or a
   cron session completes, it sends an APNs alert to every registered device. Tapping the
   notification opens that session in the app; approval notifications carry
   **Approve once / Deny** actions that answer through `approval.respond`.
4. When a turn ends it also ends the app's Live Activity via a `liveactivity` push.

## Setup from the app (recommended)

**Kitty › Settings › Notifications › Set up the push companion…** does everything except run one
command on the gateway machine:

1. You pick your `AuthKey_….p8` (Files app / iCloud Drive / AirDrop). Key ID is read from the
   filename, Team ID from the build's provisioning profile.
2. The app decides how the relay authenticates: on an ungated gateway it reuses the session
   token; on a gated one it signs the relay in *separately* (browser or password) so its
   bearer/refresh pair never collides with the phone's, and the relay refreshes it itself.
3. It uploads `hermes_push.py`, `install.sh`, `hermes-push.conf` and the `.p8` to
   `<profile home>/push/` through the dashboard's managed-files API.
4. It shows `bash <home>/push/install.sh` — or **asks Hermes to run it**, which arrives as a
   normal approval card. `install.sh` registers a systemd user service (Linux) or launchd agent
   (macOS), starts it and sends a test push to the phone.

`hermes_push.py` reads `hermes-push.conf` (`HERMES_PUSH_CONFIG`, defaulting to
`<HERMES_HOME>/push/hermes-push.conf`); environment variables override it. Rotated bearer tokens
are written back to that file.

## Setup by hand

```bash
# On the machine running `hermes serve` (placeholders only):
export HERMES_PUSH_GATEWAY_URL=http://127.0.0.1:9119          # or https://hermes.example.com
export HERMES_PUSH_GATEWAY_TOKEN=<HERMES_DASHBOARD_SESSION_TOKEN> # loopback / ungated gateway
# or, for a gated gateway: export HERMES_PUSH_GATEWAY_BEARER=<access token from /auth/native/token>
# optional Cloudflare Access service token (only if the URL is behind Access):
# export HERMES_PUSH_CF_ACCESS_CLIENT_ID=... HERMES_PUSH_CF_ACCESS_CLIENT_SECRET=...

export HERMES_PUSH_APNS_KEY_FILE=$HOME/AuthKey_XXXXXXXXXX.p8
export HERMES_PUSH_APNS_KEY_ID=XXXXXXXXXX
export HERMES_PUSH_APNS_TEAM_ID=YYYYYYYYYY
export HERMES_PUSH_APNS_TOPIC=com.vorantx.kitty        # the bundle id you build the app with

$HERMES_HOME/hermes-agent/venv/bin/python hermes_push.py
```

Dependencies (`websockets`, `PyJWT`, `cryptography`) ship in the Hermes venv; otherwise
`pip install websockets pyjwt cryptography`. `curl` with HTTP/2 must be on PATH.

Run it under systemd / launchd so it survives reboots. It reconnects with backoff.

### Check it works before trusting it

```bash
python hermes_push.py --list            # which devices have registered, and with which bundle id / APNs environment
python hermes_push.py --test            # one real "hermes-push is working" alert to every device
python hermes_push.py --dry-run         # run the relay but log payloads instead of calling APNs
```

If `--test` reaches the phone, the key, team id and topic are right and everything else is
just gateway events. A `403 InvalidProviderToken` means the key id / team id pair is wrong;
`400 BadDeviceToken` usually means the device registered from a Debug build (sandbox) while
you are sending to production or vice versa — `--list` shows each device's environment.

### Keep it running

- Linux (systemd, user session): `hermes-push.service` + `hermes-push.env.example` in this folder.
- macOS (launchd): `com.vorantx.hermes-push.plist`.

Both restart the relay on failure and at boot.

### Other Apple devices

The Mac and Apple Watch apps register the same way, with `platform` set to `macos` / `watchos`
and their own `bundle_id`; the relay sends each device on its own topic. Watch complications get
`complication` pushes on `<watch bundle id>.complication`.

## APNs key

Create a key with the *Apple Push Notifications service* capability in your Apple Developer
account, download the `.p8`, note the Key ID and Team ID. The app's `aps-environment`
entitlement is `development` for Debug builds and should be `production` for TestFlight /
App Store builds; the registration file records which environment each device uses.

## Variables

| Variable | Meaning |
|---|---|
| `HERMES_PUSH_GATEWAY_URL` | Dashboard base URL, path prefix included if reverse-proxied |
| `HERMES_PUSH_GATEWAY_TOKEN` | `X-Hermes-Session-Token` for ungated gateways (`?token=` on the socket) |
| `HERMES_PUSH_GATEWAY_BEARER` | Bearer access token for gated gateways (mints `?ticket=` via `/api/auth/ws-ticket`) |
| `HERMES_PUSH_GATEWAY_REFRESH_TOKEN` | Refresh token; on 401 the relay rotates the bearer via `/auth/native/refresh` and saves both back to the config file |
| `HERMES_PUSH_CONFIG` | KEY=VALUE file read before the environment (the app writes `<HERMES_HOME>/push/hermes-push.conf`) |
| `HERMES_PUSH_CF_ACCESS_CLIENT_ID/SECRET` | Optional Cloudflare Access service token |
| `HERMES_PUSH_APNS_KEY_FILE` / `KEY_ID` / `TEAM_ID` / `TOPIC` | Your APNs credentials and bundle id |
| `HERMES_PUSH_APNS_SANDBOX` | Force the sandbox host (otherwise per-device) |
| `HERMES_PUSH_DEVICES_DIR` | Override `<HERMES_HOME>/push/devices` |
| `HERMES_PUSH_POLL_SECONDS` | Session discovery interval (default 10) |
