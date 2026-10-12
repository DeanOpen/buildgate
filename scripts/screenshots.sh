#!/bin/bash
# Regenerates the README screenshots in docs/: starts two demo builds, gets a
# third one rejected, then captures the panel, logs, settings and menu bar.
# Needs the app installed (APP=...) and Screen Recording permission for the terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$HOME/Applications/BuildGate.app}"
OUT="$ROOT/docs"
GATE="$HOME/.buildgate/bin/buildgate"
HELPER="$ROOT/scripts/shot-helper.swift"
TMP="$(mktemp -d)"
mkdir -p "$OUT"
export PATH="$ROOT/scripts/demo-bin:$PATH"

DEMO=/Users/Shared/Projects  # no username in the screenshots
LOGS="$HOME/.buildgate/logs"

# Hide your own build logs while capturing; anything that is not a demo log
# (other builds running meanwhile) is moved back afterwards.
cleanup() {
  pkill -f "$ROOT/scripts/demo-bin" 2>/dev/null || true
  mkdir -p "$TMP/logs"
  for f in "$LOGS"/*.log; do
    [ -e "$f" ] || continue
    grep -q "^# cwd: $DEMO" "$f" && rm -f "$f" || mv "$f" "$TMP/logs/"
  done
  mv "$TMP/logs/"* "$LOGS/" 2>/dev/null || true
  rm -rf "$TMP" "$DEMO/acme-api" "$DEMO/acme-web" "$DEMO/acme-mobile"
  rmdir "$DEMO" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$TMP/logs" "$LOGS"
mv "$LOGS"/*.log "$TMP/logs/" 2>/dev/null || true

# Wait for a quiet moment so only the demo builds show up.
for _ in $(seq 300); do "$GATE" status | tail -1 | grep -q "^0/" && break; sleep 2; done
mkdir -p "$DEMO/acme-api" "$DEMO/acme-web" "$DEMO/acme-mobile"
(cd "$DEMO/acme-api" && nohup "$GATE" go build ./... >/dev/null 2>&1 &)
sleep 1.2
(cd "$DEMO/acme-web" && nohup "$GATE" pnpm build >/dev/null 2>&1 &)
sleep 3
(cd "$DEMO/acme-mobile" && "$GATE" flutter build ios >/dev/null 2>&1 || true)  # rejected: 2/2 running
sleep 4

# Opening the running app again brings it to the front (active windows, not greyed out).
launch() { pkill -x BuildGate || true; sleep 1; open "$APP" --args "$@"; sleep 3; open "$APP"; sleep 1
  osascript -e 'tell application "BuildGate" to activate' >/dev/null 2>&1 || true; sleep 1.5; }
shot() { local id; id=$(swift "$HELPER" wid "$1"); screencapture -l "$id" "$OUT/$2"; echo "docs/$2"; }

launch --panel-window --status-frame "$TMP/status"
shot "BuildGate Panel" panel.png
read -r x y w h < <(head -1 "$TMP/status")
screencapture -R "$(swift "$HELPER" rect "$x" "$y" "$w" "$h" 40)" "$OUT/menubar.png"; echo docs/menubar.png
# Other builds started meanwhile stay out of the Logs window.
for f in "$LOGS"/*.log; do grep -q "^# cwd: $DEMO" "$f" || mv "$f" "$TMP/logs/"; done
launch --open-logs flutter
shot "BuildGate Logs" logs.png
launch --open-settings
shot "BuildGate Settings" settings.png
launch
