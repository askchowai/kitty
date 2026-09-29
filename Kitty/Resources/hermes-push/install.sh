#!/usr/bin/env bash
# Installs the hermes-push companion as a user service on this machine and sends a test push.
# The Kitty app uploads this folder (<HERMES_HOME>/push/) and the config it wrote sits next to it;
# nothing here needs editing. Safe to re-run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/hermes-push.conf"

# --uninstall: stop and remove the service, the plugin folder and this push folder, so the next
# install from Kitty starts from nothing. Safe to run twice.
if [ "${1:-}" = "--uninstall" ]; then
    case "$(uname -s)" in
    Linux)
        systemctl --user disable --now hermes-push 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/hermes-push.service"
        systemctl --user daemon-reload 2>/dev/null || true
        ;;
    Darwin)
        PL="$HOME/Library/LaunchAgents/com.vorantx.hermes-push.plist"
        launchctl bootout "gui/$(id -u)" "$PL" 2>/dev/null || true
        rm -f "$PL"
        ;;
    esac
    pkill -f "$HERE/hermes_push.py" 2>/dev/null || true
    rm -rf "$(dirname "$HERE")/plugins/kitty-push"
    rm -rf "$HERE"
    echo "hermes-push removed: service stopped, plugin and $HERE deleted"
    exit 0
fi
[ -f "$CONF" ] || { echo "no $CONF — run the setup in Kitty › Settings › Notifications first"; exit 1; }

# Python with websockets + PyJWT: the Hermes venv has both.
PY=""
if command -v hermes >/dev/null 2>&1; then
    HB="$(command -v hermes)"; HB="$(readlink -f "$HB" 2>/dev/null || echo "$HB")"
    [ -x "$(dirname "$HB")/python" ] && PY="$(dirname "$HB")/python"
fi
for c in "$HOME/.hermes/hermes-agent/venv/bin/python" "$(dirname "$HERE")/hermes-agent/venv/bin/python"; do
    [ -z "$PY" ] && [ -x "$c" ] && PY="$c"
done
[ -n "$PY" ] || { echo "could not find the Hermes venv python; install deps with: pip install websockets pyjwt cryptography"; PY="$(command -v python3)"; }
echo "python: $PY"

case "$(uname -s)" in
Linux)
    UNIT_DIR="$HOME/.config/systemd/user"; mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/hermes-push.service" <<EOF
[Unit]
Description=hermes-push — APNs relay for the Kitty apps
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HERMES_PUSH_CONFIG=$CONF
ExecStart=$PY $HERE/hermes_push.py
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now hermes-push
    loginctl enable-linger "$USER" 2>/dev/null || true
    echo "service: $(systemctl --user is-active hermes-push)"
    ;;
Darwin)
    PL="$HOME/Library/LaunchAgents/com.vorantx.hermes-push.plist"; mkdir -p "$(dirname "$PL")"
    cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.vorantx.hermes-push</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$HERE/hermes_push.py</string></array>
  <key>EnvironmentVariables</key><dict><key>HERMES_PUSH_CONFIG</key><string>$CONF</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HERE/hermes-push.log</string>
  <key>StandardErrorPath</key><string>$HERE/hermes-push.log</string>
</dict></plist>
EOF
    launchctl bootout "gui/$(id -u)" "$PL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PL"
    echo "launchd agent loaded"
    ;;
*) echo "unsupported OS: $(uname -s); run: HERMES_PUSH_CONFIG=$CONF $PY $HERE/hermes_push.py"; ;;
esac

echo "sending a test push…"
HERMES_PUSH_CONFIG="$CONF" "$PY" "$HERE/hermes_push.py" --test
